//! The file system as the client sees it: the staged bundle read-only from the host, and the
//! app's container in memory, so nothing outside the emulator changes. On the device the
//! client's working directory is the folder holding its .app, and its Application Support is
//! the launcher's container. The sandbox refuses the folders above the container (EPERM), the
//! cautious reading of an app's sandbox, which ContainerPaths.c answers for.
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use super::{Ctx, Registry, Stop};
use crate::machine::Machine;

/// An iOS app's HOME: its container.
pub const CONTAINER: &str = "/var/mobile/Containers/Data/Application/POCKET";

const EPERM: i32 = 1;
const ENOENT: i32 = 2;
const EBADF: i32 = 9;
const EACCES: i32 = 13;
const EEXIST: i32 = 17;
const EISDIR: i32 = 21;
const EINVAL: i32 = 22;
const ENOTTY: i32 = 25;
const O_ACCMODE: u32 = 3;
const O_APPEND: u32 = 0x8;
const O_CREAT: u32 = 0x200;
const O_TRUNC: u32 = 0x400;
const O_EXCL: u32 = 0x800;
const FAIL32: u64 = 0xFFFF_FFFF;
const FAIL64: u64 = u64::MAX;
const S_IFDIR: u16 = 0o040000;
const S_IFREG: u16 = 0o100000;

type Buffer = Arc<Mutex<Vec<u8>>>;

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Kind {
    Dir,
    File,
}

/// The bundle's path and the container's folders and files.
pub struct Vfs {
    app: PathBuf,
    directories: HashSet<String>,
    files: HashMap<String, Buffer>,
}

impl Vfs {
    pub fn new(app: &Path) -> Vfs {
        let directories = ["", "/Library", "/Library/Application Support", "/Documents", "/tmp"]
            .iter()
            .map(|folder| format!("{CONTAINER}{folder}"))
            .collect();
        Vfs { app: app.to_path_buf(), directories, files: HashMap::new() }
    }

    /// The host path of a bundle path (the same path: the bundle is where it is staged).
    fn host_path(&self, path: &str) -> Option<PathBuf> {
        let app = self.app.to_string_lossy();
        (path == app || path.strip_prefix(app.as_ref()).is_some_and(|rest| rest.starts_with('/'))).then(|| PathBuf::from(path))
    }

    pub fn kind(&self, path: &str) -> Option<Kind> {
        if let Some(real) = self.host_path(path) {
            return if real.is_dir() {
                Some(Kind::Dir)
            } else if real.is_file() {
                Some(Kind::File)
            } else {
                None
            };
        }
        // The container's own ancestors exist (so mkdir of them answers EEXIST, as on the device).
        if self.directories.contains(path) || path == "/" || CONTAINER.starts_with(&format!("{}/", path.trim_end_matches('/'))) {
            return Some(Kind::Dir);
        }
        self.files.contains_key(path).then_some(Kind::File)
    }

    /// mkdir -p inside the container, as -[NSFileManager createDirectoryAtPath:...] would.
    pub fn make_directories(&mut self, path: &str) -> bool {
        if !in_container(path) {
            return false;
        }
        let parts: Vec<&str> = path[CONTAINER.len()..].trim_matches('/').split('/').collect();
        for i in 1..=parts.len() {
            self.directories.insert(format!("{CONTAINER}/{}", parts[..i].join("/")));
        }
        true
    }

    /// opendir's answer: Ok for the container's and the bundle's folders, else the errno.
    pub fn opendir(&self, path: &str) -> Result<(), i32> {
        let found = self.kind(path);
        if found == Some(Kind::Dir) && (in_container(path) || self.host_path(path).is_some()) {
            return Ok(());
        }
        Err(if found == Some(Kind::Dir) { EPERM } else { ENOENT })
    }
}

pub fn in_container(path: &str) -> bool {
    path == CONTAINER || path.strip_prefix(CONTAINER).is_some_and(|rest| rest.starts_with('/'))
}

fn parent(path: &str) -> &str {
    path.rsplit_once('/').map_or("", |(head, _)| head)
}

struct Entry {
    path: String,
    data: Buffer,
    pos: u64,
    writable: bool,
    append: bool,
}

struct Files {
    vfs: Vfs,
    fds: HashMap<i32, Entry>,
    next_fd: i32,
    bundle: HashMap<String, Buffer>, // the bundle's files read so far, by path
}

impl Default for Files {
    fn default() -> Files {
        Files { vfs: Vfs::new(Path::new("/nonexistent.app")), fds: HashMap::new(), next_fd: 10, bundle: HashMap::new() }
    }
}

fn state(m: &Machine) -> Arc<Mutex<Files>> {
    m.state::<Files>()
}

pub fn register(r: &mut Registry) {
    r.answer(&["_open"], open);
    r.answer(&["_pread"], |c| {
        let files = state(c.m);
        let files = files.lock().unwrap();
        let Some(entry) = files.fds.get(&(c.arg32(0) as i32)) else { return bad(c, FAIL64) };
        let data = entry.data.lock().unwrap();
        let start = (c.arg(3) as usize).min(data.len());
        let end = start.saturating_add(c.arg(2) as usize).min(data.len());
        c.mem().write(c.arg(1), &data[start..end]);
        Ok(Some((end - start) as u64))
    });
    r.answer(&["_pwrite"], |c| {
        let files = state(c.m);
        let files = files.lock().unwrap();
        let Some(entry) = files.fds.get(&(c.arg32(0) as i32)).filter(|e| e.writable) else { return bad(c, FAIL64) };
        put(&mut entry.data.lock().unwrap(), c.arg(3) as usize, c.mem().slice(c.arg(1), c.arg(2) as usize));
        Ok(Some(c.arg(2)))
    });
    r.answer(&["_lseek"], |c| {
        let files = state(c.m);
        let mut files = files.lock().unwrap();
        let Some(entry) = files.fds.get_mut(&(c.arg32(0) as i32)) else { return bad(c, FAIL64) };
        let base = match c.arg32(2) {
            0 => 0,
            1 => entry.pos,
            2 => entry.data.lock().unwrap().len() as u64,
            _ => {
                c.set_errno(EINVAL);
                return Ok(Some(FAIL64));
            }
        };
        entry.pos = base.wrapping_add(c.arg(1));
        Ok(Some(entry.pos))
    });
    r.answer(&["_ftruncate"], |c| {
        let files = state(c.m);
        let files = files.lock().unwrap();
        let Some(entry) = files.fds.get(&(c.arg32(0) as i32)).filter(|e| e.writable) else {
            c.set_errno(EINVAL);
            return Ok(Some(FAIL32));
        };
        entry.data.lock().unwrap().resize(c.arg(1) as usize, 0);
        Ok(Some(0))
    });
    r.answer(&["_stat", "_lstat"], |c| {
        let path = c.cstring(c.arg(0));
        let files = state(c.m);
        let files = files.lock().unwrap();
        match files.vfs.kind(&path) {
            None => {
                c.set_errno(ENOENT);
                Ok(Some(FAIL32))
            }
            Some(Kind::Dir) => {
                write_stat(c, c.arg(1), 0, S_IFDIR | 0o755);
                Ok(Some(0))
            }
            Some(Kind::File) => {
                let size = match files.vfs.host_path(&path) {
                    Some(real) => std::fs::metadata(real).map_or(0, |m| m.len()),
                    None => files.vfs.files[&path].lock().unwrap().len() as u64,
                };
                write_stat(c, c.arg(1), size, S_IFREG | 0o644);
                Ok(Some(0))
            }
        }
    });
    r.answer(&["_fstat"], |c| {
        let files = state(c.m);
        let files = files.lock().unwrap();
        let Some(entry) = files.fds.get(&(c.arg32(0) as i32)) else { return bad(c, FAIL32) };
        let size = entry.data.lock().unwrap().len() as u64;
        write_stat(c, c.arg(1), size, S_IFREG | 0o644);
        Ok(Some(0))
    });
    r.answer(&["_access"], |c| {
        let path = c.cstring(c.arg(0));
        if !exists(c.m, &path) {
            c.set_errno(ENOENT);
            return Ok(Some(FAIL32));
        }
        if c.arg(1) & 2 != 0 && !in_container(&path) {
            c.set_errno(EACCES);
            return Ok(Some(FAIL32));
        }
        Ok(Some(0))
    });
    r.answer(&["_getcwd"], |c| {
        let app = state(c.m).lock().unwrap().vfs.app.clone();
        let cwd = app.parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        let buffer = if c.arg(0) != 0 { c.arg(0) } else { c.alloc(cwd.len() as u64 + 1) };
        c.mem().write(buffer, cwd.as_bytes());
        c.mem().set_u8(buffer + cwd.len() as u64, 0);
        Ok(Some(buffer))
    });
    r.answer(&["_mkdir"], |c| {
        let path = c.cstring(c.arg(0)).trim_end_matches('/').to_string();
        c.m.report.file_opened(format!("mkdir {path}"));
        let files = state(c.m);
        let mut files = files.lock().unwrap();
        if files.vfs.kind(&path).is_some() {
            c.set_errno(EEXIST);
            return Ok(Some(FAIL32));
        }
        if !in_container(&path) || !files.vfs.directories.contains(parent(&path)) {
            c.set_errno(if in_container(&path) { ENOENT } else { EACCES });
            return Ok(Some(FAIL32));
        }
        files.vfs.directories.insert(path);
        Ok(Some(0))
    });
    r.answer(&["_unlink", "_remove"], |c| {
        let path = c.cstring(c.arg(0));
        let files = state(c.m);
        let mut files = files.lock().unwrap();
        if files.vfs.files.remove(&path).is_some() {
            return Ok(Some(0));
        }
        c.set_errno(if files.vfs.host_path(&path).is_some() { EACCES } else { ENOENT });
        Ok(Some(FAIL32))
    });
    r.answer(&["_rmdir"], |c| {
        let path = c.cstring(c.arg(0)).trim_end_matches('/').to_string();
        let files = state(c.m);
        let mut files = files.lock().unwrap();
        if in_container(&path) && files.vfs.directories.remove(&path) {
            return Ok(Some(0));
        }
        c.set_errno(ENOENT);
        Ok(Some(FAIL32))
    });
    r.answer(&["_rename"], |c| {
        let (old, new) = (c.cstring(c.arg(0)), c.cstring(c.arg(1)));
        let files = state(c.m);
        let mut files = files.lock().unwrap();
        if files.vfs.files.contains_key(&old) && in_container(&new) && files.vfs.directories.contains(parent(&new)) {
            let data = files.vfs.files.remove(&old).expect("checked");
            files.vfs.files.insert(new, data);
            return Ok(Some(0));
        }
        c.set_errno(ENOENT);
        Ok(Some(FAIL32))
    });
    r.answer(&["_fsync", "_fchmod", "_fchown", "_futimes", "_utimes", "_flock"], |_| Ok(Some(0)));
    r.answer(&["_statfs", "_fstatfs"], |c| {
        c.mem().fill(c.arg(1), 0, 2168);
        Ok(Some(0))
    });
    r.answer(&["_fsctl"], |c| {
        c.set_errno(ENOTTY);
        Ok(Some(FAIL32))
    });
    r.answer(&["_readlink"], |c| {
        c.set_errno(EINVAL);
        Ok(Some(FAIL64))
    });
    r.answer(&["_opendir"], |c| {
        let path = c.cstring(c.arg(0));
        let path = match path.trim_end_matches('/') {
            "" => "/".to_string(),
            trimmed => trimmed.to_string(),
        };
        c.m.report.file_opened(format!("opendir {path}"));
        let answer = state(c.m).lock().unwrap().vfs.opendir(&path);
        match answer {
            Ok(()) => Ok(Some(c.alloc(64))),
            Err(errno) => {
                c.set_errno(errno);
                Ok(Some(0))
            }
        }
    });
    r.answer(&["_closedir"], |_| Ok(Some(0)));
    r.answer(&["_NSSearchPathForDirectoriesInDomains"], |c| {
        // NSApplicationSupportDirectory (14), NSDocumentDirectory (9), NSCachesDirectory (13)
        let folder = match c.arg32(0) {
            14 => Some("/Library/Application Support"),
            9 => Some("/Documents"),
            13 => Some("/Library/Caches"),
            _ => None,
        };
        let Some(folder) = folder else { return Ok(Some(super::objc::new_array(c.m, Vec::new()))) };
        {
            let files = state(c.m);
            let mut files = files.lock().unwrap();
            let above = parent(folder);
            if !above.is_empty() {
                files.vfs.directories.insert(format!("{CONTAINER}{above}"));
            }
            files.vfs.directories.insert(format!("{CONTAINER}{folder}"));
        }
        let path = super::objc::new_string(c.m, &format!("{CONTAINER}{folder}"));
        Ok(Some(super::objc::new_array(c.m, vec![path])))
    });
}

fn bad(c: &Ctx, fail: u64) -> Result<Option<u64>, Stop> {
    c.set_errno(EBADF);
    Ok(Some(fail))
}

fn put(buffer: &mut Vec<u8>, offset: usize, data: &[u8]) {
    if buffer.len() < offset + data.len() {
        buffer.resize(offset + data.len(), 0);
    }
    buffer[offset..offset + data.len()].copy_from_slice(data);
}

/// struct stat (64-bit inode): st_mode at 4, st_size at 96, st_blksize at 112.
fn write_stat(c: &Ctx, buffer: u64, size: u64, mode: u16) {
    c.mem().fill(buffer, 0, 144);
    c.mem().set_u16(buffer + 4, mode);
    c.mem().set_u64(buffer + 96, size);
    c.mem().set_i32(buffer + 112, 4096);
}

fn open(c: &mut Ctx) -> Result<Option<u64>, Stop> {
    let (path, flags) = (c.cstring(c.arg(0)), c.arg32(1));
    c.m.report.file_opened(format!("open {path} ({flags:#x})"));
    let files = state(c.m);
    let mut files = files.lock().unwrap();
    let found = files.vfs.kind(&path);
    let fail = |errno| {
        c.set_errno(errno);
        Ok(Some(FAIL32))
    };
    let entry = if files.vfs.host_path(&path).is_some() {
        if flags & O_ACCMODE != 0 || found != Some(Kind::File) {
            return fail(if found.is_some() { EACCES } else { ENOENT });
        }
        // A bundle file is read from disk once and shared by every open of it (read-only).
        let data = match files.bundle.get(&path) {
            Some(data) => data.clone(),
            None => {
                let Ok(bytes) = std::fs::read(&path) else { return fail(EACCES) };
                let data: Buffer = Arc::new(Mutex::new(bytes));
                files.bundle.insert(path.clone(), data.clone());
                data
            }
        };
        Entry { path, data, pos: 0, writable: false, append: false }
    } else {
        if !in_container(&path) {
            return fail(ENOENT);
        }
        match found {
            Some(Kind::Dir) => return fail(EISDIR),
            None => {
                if flags & O_CREAT == 0 || !files.vfs.directories.contains(parent(&path)) {
                    return fail(ENOENT);
                }
                files.vfs.files.insert(path.clone(), Buffer::default());
            }
            Some(Kind::File) if flags & O_CREAT != 0 && flags & O_EXCL != 0 => return fail(EEXIST),
            Some(Kind::File) => {}
        }
        if flags & O_TRUNC != 0 {
            files.vfs.files.insert(path.clone(), Buffer::default());
        }
        let data = files.vfs.files[&path].clone();
        Entry { path, data, pos: 0, writable: flags & O_ACCMODE != 0, append: flags & O_APPEND != 0 }
    };
    let fd = files.next_fd;
    files.next_fd += 1;
    files.fds.insert(fd, entry);
    Ok(Some(fd as u64))
}

pub fn prepare(m: &Machine, app: &Path) -> Result<(), String> {
    state(m).lock().unwrap().vfs = Vfs::new(app);
    Ok(())
}
pub fn finish(_m: &Machine) {}
pub fn problems(_m: &Machine) -> Vec<String> {
    Vec::new()
}
pub fn sections(_m: &Machine) -> Vec<(String, Vec<String>)> {
    Vec::new()
}

/// Whether a path exists (a bundle path on the host, or the container's).
pub fn exists(m: &Machine, path: &str) -> bool {
    state(m).lock().unwrap().vfs.kind(path).is_some()
}

/// mkdir -p inside the container; false outside it.
pub fn make_directories(m: &Machine, path: &str) -> bool {
    state(m).lock().unwrap().vfs.make_directories(path)
}

/// Copy `length` bytes of an open file from `offset` to guest memory at `to` (mmap): false if
/// `fd` is not an open file. Bytes past the file's end are left as they are (zero).
pub fn map_into(c: &super::Ctx, fd: i32, offset: u64, to: u64, length: u64) -> bool {
    let Some(data) = state(c.m).lock().unwrap().fds.get(&fd).map(|entry| entry.data.clone()) else { return false };
    let data = data.lock().unwrap();
    let start = (offset as usize).min(data.len());
    let end = start.saturating_add(length as usize).min(data.len());
    c.mem().write(to, &data[start..end]);
    true
}

/// A new file descriptor number (sockets come from the same numbers as files).
pub fn new_fd(c: &super::Ctx) -> i32 {
    let files = state(c.m);
    let mut files = files.lock().unwrap();
    let fd = files.next_fd;
    files.next_fd += 1;
    fd
}

/// read, write, close and fcntl for descriptors that are not sockets: the network module
/// answers those four imports and hands everything but its sockets to these.
pub fn read(c: &mut super::Ctx) -> Result<Option<u64>, super::Stop> {
    let files = state(c.m);
    let mut files = files.lock().unwrap();
    let Some(entry) = files.fds.get_mut(&(c.arg32(0) as i32)) else { return bad(c, FAIL64) };
    let data = entry.data.lock().unwrap();
    let start = (entry.pos as usize).min(data.len());
    let end = start.saturating_add(c.arg(2) as usize).min(data.len());
    c.mem().write(c.arg(1), &data[start..end]);
    drop(data);
    entry.pos += (end - start) as u64;
    Ok(Some((end - start) as u64))
}

pub fn write(c: &mut super::Ctx) -> Result<Option<u64>, super::Stop> {
    let (fd, size) = (c.arg32(0) as i32, c.arg(2));
    let data = c.mem().slice(c.arg(1), size as usize);
    if fd == 1 || fd == 2 {
        c.console(String::from_utf8_lossy(data).into_owned());
        return Ok(Some(size));
    }
    let files = state(c.m);
    let mut files = files.lock().unwrap();
    let Some(entry) = files.fds.get_mut(&fd).filter(|e| e.writable) else { return bad(c, FAIL64) };
    let mut buffer = entry.data.lock().unwrap();
    if entry.append {
        entry.pos = buffer.len() as u64;
    }
    put(&mut buffer, entry.pos as usize, data);
    drop(buffer);
    entry.pos += size;
    Ok(Some(size))
}

pub fn close(c: &mut super::Ctx) -> Result<Option<u64>, super::Stop> {
    if state(c.m).lock().unwrap().fds.remove(&(c.arg32(0) as i32)).is_some() {
        return Ok(Some(0));
    }
    bad(c, FAIL32)
}

/// One process, so every lock is granted; F_GETLK reports the range unlocked. The third
/// argument is variadic: on the stack.
pub fn fcntl(c: &mut super::Ctx) -> Result<Option<u64>, super::Stop> {
    match c.arg32(1) {
        // F_GETLK: struct flock's l_type (offset 20) becomes F_UNLCK
        7 => c.mem().set_u16(c.stack(0) + 20, 2),
        // F_GETPATH
        50 => {
            if let Some(entry) = state(c.m).lock().unwrap().fds.get(&(c.arg32(0) as i32)) {
                c.mem().write(c.stack(0), entry.path.as_bytes());
                c.mem().set_u8(c.stack(0) + entry.path.len() as u64, 0);
            }
        }
        _ => {}
    }
    Ok(Some(0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn container_paths() {
        assert!(in_container(CONTAINER));
        assert!(in_container(&format!("{CONTAINER}/Documents/a")));
        assert!(!in_container(&format!("{CONTAINER}X")));
        assert!(!in_container("/var/mobile"));
        assert_eq!(parent("/a/b/c"), "/a/b");
    }

    #[test]
    fn kinds_and_directories() {
        let mut vfs = Vfs::new(Path::new("/nonexistent/Game.app"));
        assert_eq!(vfs.kind("/"), Some(Kind::Dir));
        assert_eq!(vfs.kind("/var/mobile/"), Some(Kind::Dir));
        assert_eq!(vfs.kind(&format!("{CONTAINER}/Library")), Some(Kind::Dir));
        assert_eq!(vfs.kind(&format!("{CONTAINER}/Library/Caches")), None);
        assert!(vfs.make_directories(&format!("{CONTAINER}/Library/Caches/x/y")));
        assert_eq!(vfs.kind(&format!("{CONTAINER}/Library/Caches/x")), Some(Kind::Dir));
        assert!(!vfs.make_directories("/tmp/x"));
        vfs.files.insert(format!("{CONTAINER}/f"), Buffer::default());
        assert_eq!(vfs.kind(&format!("{CONTAINER}/f")), Some(Kind::File));
        assert_eq!(vfs.kind("/nonexistent/Game.app/x"), None);
    }

    #[test]
    fn sandbox_refuses_above_the_container() {
        let vfs = Vfs::new(Path::new("/nonexistent/Game.app"));
        assert_eq!(vfs.opendir(CONTAINER), Ok(()));
        assert_eq!(vfs.opendir("/var/mobile/Containers"), Err(EPERM));
        assert_eq!(vfs.opendir("/"), Err(EPERM));
        assert_eq!(vfs.opendir("/etc"), Err(ENOENT));
    }

    #[test]
    fn put_extends() {
        let mut buffer = vec![1, 2];
        put(&mut buffer, 4, &[9]);
        assert_eq!(buffer, vec![1, 2, 0, 0, 9]);
    }
}
