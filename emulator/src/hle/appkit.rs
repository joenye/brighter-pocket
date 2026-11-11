//! Which selectors the device's AppKit answers: Tolkara's AppKit adapter with this layer.
//!
//! Read from the prepared tree (tools/prepare.py), so the emulator asks exactly what a build
//! from it would have: each `@implementation`'s methods, each `@property` of an `@interface`
//! (synthesized), the superclass chain from the `@interface` lines, and what
//! pocket/translation/AppKit/PocketCompat.m adds at load with class_addMethod. Classes the
//! client imports from AppKit that the adapter does not define are the platform's stub
//! classes: they answer NSObject's own methods and nothing else.
use std::collections::{HashMap, HashSet};
use std::path::Path;

const NSOBJECT: &[&str] = &[
    "alloc", "new", "init", "retain", "release", "autorelease", "self", "class", "superclass", "copy",
    "isKindOfClass:", "isMemberOfClass:", "respondsToSelector:", "conformsToProtocol:", "isEqual:", "hash",
    "description", "debugDescription", "performSelector:", "performSelector:withObject:",
    "performSelector:withObject:withObject:", "isProxy", "zone", "retainCount",
];

/// PocketCompat.m's constructor, which adds these where the class lacks them (checked against
/// the source, so a change there shows up here).
const ADDED_AT_LOAD: &[(&str, bool, &[&str])] = &[
    ("NSCursor", true, &["IBeamCursor", "crosshairCursor", "pointingHandCursor", "operationNotAllowedCursor"]),
    ("NSBitmapImageRep", true, &["imageRepWithData:"]),
];

#[derive(Default)]
pub struct Coverage {
    methods: HashMap<(String, bool), HashSet<String>>,
    superclass: HashMap<String, String>,
    classes: HashSet<String>,
    /// PocketCompat.m is in the tree (absent in the pinned platform alone).
    pub compat: bool,
}

fn is_word(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

fn skip_space(t: &[u8], mut i: usize) -> usize {
    while i < t.len() && t[i].is_ascii_whitespace() {
        i += 1;
    }
    i
}

fn word_end(t: &[u8], mut i: usize) -> usize {
    while i < t.len() && is_word(t[i]) {
        i += 1;
    }
    i
}

fn find(t: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    if from > t.len() {
        return None;
    }
    t[from..].windows(needle.len()).position(|w| w == needle).map(|p| p + from)
}

fn text(t: &[u8], a: usize, b: usize) -> String {
    String::from_utf8_lossy(&t[a..b]).into_owned()
}

/// A method's selector from its signature: its keywords, or its name when it takes none.
pub fn selector_of(signature: &str) -> String {
    let t = signature.as_bytes();
    let mut parts = String::new();
    let mut i = 0;
    while i < t.len() {
        if is_word(t[i]) {
            let end = word_end(t, i);
            let after = skip_space(t, end);
            if after < t.len() && t[after] == b':' {
                parts.push_str(&text(t, i, end));
                parts.push(':');
            }
            i = end;
        } else {
            i += 1;
        }
    }
    if parts.is_empty() { signature.split_whitespace().next().unwrap_or("").to_string() } else { parts }
}

impl Coverage {
    /// The coverage of the tree at `tree`, for a client importing `imported` from AppKit.
    pub fn read(tree: &Path, imported: &HashSet<String>) -> Result<Coverage, String> {
        let mut sources = Vec::new();
        for folder in ["translation/AppKit", "translation/AKSupport"] {
            let mut found: Vec<_> = std::fs::read_dir(tree.join(folder))
                .map_err(|e| format!("{}: {e}", tree.join(folder).display()))?
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| matches!(p.extension().and_then(|e| e.to_str()), Some("h" | "m")))
                .collect();
            found.sort();
            sources.extend(found);
        }
        let mut coverage = Coverage::default();
        let mut defined = HashSet::new();
        for source in sources {
            let bytes = std::fs::read(&source).map_err(|e| format!("{}: {e}", source.display()))?;
            coverage.add_source(&bytes, &mut defined);
        }
        let compat_file = tree.join("translation/AppKit/PocketCompat.m");
        coverage.compat = compat_file.is_file();
        if coverage.compat {
            let compat = std::fs::read_to_string(&compat_file).map_err(|e| e.to_string())?;
            for (name, class_side, selectors) in ADDED_AT_LOAD {
                for selector in *selectors {
                    if !compat.contains(selector) {
                        return Err(format!("PocketCompat.m no longer adds {selector}; update src/hle/appkit.rs"));
                    }
                    coverage.methods.entry((name.to_string(), *class_side)).or_default().insert(selector.to_string());
                }
                defined.insert(name.to_string());
            }
        }
        coverage.classes = defined.union(imported).cloned().collect();
        Ok(coverage)
    }

    /// One source file's interfaces, implementations and properties.
    pub fn add_source(&mut self, t: &[u8], defined: &mut HashSet<String>) {
        // `@interface Name : Super` lines: the superclass chain.
        let mut i = 0;
        while let Some(at) = find(t, i, b"@interface") {
            i = at + 1;
            let start = at + b"@interface".len();
            let name_at = skip_space(t, start);
            if name_at == start {
                continue;
            }
            let name_end = word_end(t, name_at);
            let colon = skip_space(t, name_end);
            if name_end == name_at || colon >= t.len() || t[colon] != b':' {
                continue;
            }
            let super_at = skip_space(t, colon + 1);
            let super_end = word_end(t, super_at);
            if super_end > super_at {
                self.superclass.entry(text(t, name_at, name_end)).or_insert_with(|| text(t, super_at, super_end));
            }
        }
        // `@implementation` and `@interface` blocks up to their `@end`.
        let mut i = 0;
        while i < t.len() {
            let Some((at, kind)) = [b"@implementation".as_slice(), b"@interface".as_slice()]
                .iter()
                .filter_map(|k| find(t, i, k).map(|p| (p, *k)))
                .min_by_key(|(p, _)| *p)
            else {
                break;
            };
            let start = at + kind.len();
            let name_at = skip_space(t, start);
            let name_end = word_end(t, name_at);
            if name_at == start || name_end == name_at {
                i = at + 1;
                continue;
            }
            let Some(end) = find(t, name_end, b"@end") else {
                i = at + 1;
                continue;
            };
            let name = text(t, name_at, name_end);
            let mut body_at = skip_space(t, name_end);
            let mut category = false;
            if body_at < t.len() && t[body_at] == b'(' {
                let inner = skip_space(t, word_end(t, skip_space(t, body_at + 1)));
                if inner < end && t[inner] == b')' {
                    category = true;
                    body_at = inner + 1;
                }
            }
            let implementation = kind == b"@implementation";
            if implementation && !category {
                defined.insert(name.clone());
            }
            let body = &t[body_at..end];
            if implementation {
                for (class_side, selector) in methods(body) {
                    self.methods.entry((name.clone(), class_side)).or_default().insert(selector);
                }
            }
            for (class_side, selectors) in properties(body) {
                self.methods.entry((name.clone(), class_side)).or_default().extend(selectors);
            }
            i = end + b"@end".len();
        }
    }

    pub fn contains(&self, name: &str) -> bool {
        self.classes.contains(name)
    }

    pub fn implements(&self, name: &str, selector: &str, class_side: bool) -> bool {
        if NSOBJECT.contains(&selector) {
            return true;
        }
        let mut seen = HashSet::new();
        let mut name = Some(name.to_string());
        while let Some(current) = name {
            if !seen.insert(current.clone()) {
                break;
            }
            if self.methods.get(&(current.clone(), class_side)).is_some_and(|m| m.contains(selector)) {
                return true;
            }
            name = self.superclass.get(&current).cloned();
        }
        false
    }
}

/// `- (type)signature` and `+ (type)signature` at the start of a line: (class side, selector).
fn methods(t: &[u8]) -> Vec<(bool, String)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < t.len() {
        if i == 0 || t[i - 1] == b'\n' {
            if let Some((side, end)) = method_at(t, i) {
                out.push(side);
                i = end;
                continue;
            }
        }
        i += 1;
    }
    out
}

fn method_at(t: &[u8], i: usize) -> Option<((bool, String), usize)> {
    let mut p = skip_space(t, i);
    let class_side = match t.get(p)? {
        b'+' => true,
        b'-' => false,
        _ => return None,
    };
    p = skip_space(t, p + 1);
    if t.get(p)? != &b'(' {
        return None;
    }
    p = p + find(&t[p..], 0, b")")?;
    let start = skip_space(t, p + 1);
    let mut end = start;
    while end < t.len() && t[end] != b';' && t[end] != b'{' {
        end += 1;
    }
    if end == start {
        return None;
    }
    Some(((class_side, selector_of(&text(t, start, end))), end))
}

/// `@property (attributes) type name;`: the getter (or getter=), and the setter unless readonly.
fn properties(t: &[u8]) -> Vec<(bool, Vec<String>)> {
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(at) = find(t, i, b"@property") {
        i = at + 1;
        let mut p = skip_space(t, at + b"@property".len());
        let mut attributes = String::new();
        if t.get(p) == Some(&b'(') {
            if let Some(close) = find(t, p, b")") {
                attributes = text(t, p, close + 1);
                p = close + 1;
            }
        }
        let Some(semicolon) = t[p..].iter().position(|&b| b == b';').map(|q| q + p) else { continue };
        let mut word_end = semicolon;
        while word_end > p && t[word_end - 1].is_ascii_whitespace() {
            word_end -= 1;
        }
        let mut word_start = word_end;
        while word_start > p && is_word(t[word_start - 1]) {
            word_start -= 1;
        }
        if word_start == word_end {
            continue;
        }
        let prop = text(t, word_start, word_end);
        let getter = attributes.find("getter").and_then(|g| {
            let rest = attributes[g + 6..].trim_start().strip_prefix('=')?.trim_start();
            let name: String = rest.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '_').collect();
            (!name.is_empty()).then_some(name)
        });
        let mut selectors = vec![getter.unwrap_or_else(|| prop.clone())];
        if !attributes.contains("readonly") {
            let mut chars = prop.chars();
            let first = chars.next().map(|c| c.to_ascii_uppercase()).unwrap_or_default();
            selectors.push(format!("set{first}{}:", chars.as_str()));
        }
        out.push((attributes.contains("class"), selectors));
        i = semicolon + 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selectors_from_signatures() {
        assert_eq!(selector_of("frame"), "frame");
        assert_eq!(selector_of("setFrame:(NSRect)frame display:(BOOL)flag"), "setFrame:display:");
        assert_eq!(selector_of("sendEvent:(NSEvent *)event "), "sendEvent:");
    }

    #[test]
    fn reads_classes_methods_and_properties() {
        let source = br#"
@interface NSResponder : NSObject
@end
@interface NSWindow : NSResponder
@property (nonatomic, readonly) NSRect frame;
@property (nonatomic, getter=isVisible) BOOL visible;
@property (class, readonly) NSWindow *shared;
@property (copy) void (^handler)(void);
@end
@implementation NSResponder
- (void)mouseDown:(NSEvent *)event { }
@end
@implementation NSWindow
+ (instancetype)windowWithContentRect:(NSRect)rect styleMask:(NSUInteger)mask
{
}
- (void)center;
@end
@implementation NSWindow (Extras)
- (void)extra { }
@end
"#;
        let mut coverage = Coverage::default();
        let mut defined = HashSet::new();
        coverage.add_source(source, &mut defined);
        coverage.classes = defined.clone();
        assert_eq!(defined, ["NSResponder", "NSWindow"].iter().map(|s| s.to_string()).collect());
        assert!(coverage.implements("NSWindow", "frame", false));
        assert!(!coverage.implements("NSWindow", "setFrame:", false));
        assert!(coverage.implements("NSWindow", "isVisible", false));
        assert!(coverage.implements("NSWindow", "setVisible:", false));
        assert!(coverage.implements("NSWindow", "shared", true));
        assert!(coverage.implements("NSWindow", "windowWithContentRect:styleMask:", true));
        assert!(coverage.implements("NSWindow", "mouseDown:", false));
        assert!(coverage.implements("NSWindow", "extra", false));
        assert!(coverage.implements("NSWindow", "retain", false));
        assert!(coverage.implements("NSWindow", "center", false));
        assert!(!coverage.implements("NSWindow", "setMaxSize:", false));
        assert!(!coverage.implements("NSWindow", "handler", false));
    }
}
