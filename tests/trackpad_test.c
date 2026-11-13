// The touch trackpad's gestures (translation/AppKit/TouchTrackpad.c with pocket/patches/0025),
// on the host: a tap is a left click once the double-tap time is up, two taps are one right
// click, a move after a tap clicks first, a pinch scrolls and never clicks, a two-finger tap is
// a right click, and a held finger drags.
#include "TouchTrackpad.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct { AKTrackpadAction action; double x, y; unsigned button; } Event;
static Event events[64];
static int count;
static void emit(void *context, AKTrackpadAction action, double x, double y, unsigned button) {
    (void)context;
    assert(count < 64);
    events[count++] = (Event){action, x, y, button};
}
static void reset(AKTrackpad *pad) { memset(pad, 0, sizeof *pad); count = 0; }
static void touch(AKTrackpad *pad, unsigned fingers, double x, double y, double spread, double time) {
    AKTrackpadUpdate(pad, fingers, x, y, spread, time, emit, NULL);
}
static int clicks(unsigned button) {
    int found = 0;
    for (int i = 0; i + 1 < count; i++)
        if (events[i].action == AKTrackpadDown && events[i + 1].action == AKTrackpadUp &&
            events[i].button == button && events[i + 1].button == button) found++;
    return found;
}
static int scrolled(void) {
    int lines = 0;
    for (int i = 0; i < count; i++) if (events[i].action == AKTrackpadScroll) lines += (int)events[i].y;
    return lines;
}

int main(void) {
    AKTrackpad pad;

    // One tap: nothing until the double-tap time is up, then a left click.
    reset(&pad);
    touch(&pad, 1, 100, 100, 0, 1.00);
    touch(&pad, 0, 0, 0, 0, 1.10);
    assert(count == 0 && pad.tapPending);
    AKTrackpadFlush(&pad, 1.20, emit, NULL);
    assert(count == 0);
    AKTrackpadFlush(&pad, 1.10 + AKTrackpadDoubleTap, emit, NULL);
    assert(count == 2 && clicks(0) == 1 && !pad.tapPending);

    // Two taps: one right click, no left click; jitter of the second does not move the cursor.
    reset(&pad);
    touch(&pad, 1, 100, 100, 0, 2.00);
    touch(&pad, 0, 0, 0, 0, 2.08);
    touch(&pad, 1, 101, 100, 0, 2.20);
    touch(&pad, 1, 102, 101, 0, 2.22);
    touch(&pad, 0, 0, 0, 0, 2.28);
    assert(count == 2 && clicks(1) == 1 && clicks(0) == 0 && !pad.tapPending);

    // A tap, then a slide: the left click first, then the whole move from where the slide began.
    reset(&pad);
    touch(&pad, 1, 100, 100, 0, 3.00);
    touch(&pad, 0, 0, 0, 0, 3.08);
    touch(&pad, 1, 100, 100, 0, 3.20);
    touch(&pad, 1, 105, 100, 0, 3.22);
    assert(count == 0);
    touch(&pad, 1, 120, 100, 0, 3.25);
    assert(count == 3 && clicks(0) == 1 && events[2].action == AKTrackpadMove && events[2].x == 20);

    // A tap long ago, then another: two single taps, never a right click.
    reset(&pad);
    touch(&pad, 1, 100, 100, 0, 4.00);
    touch(&pad, 0, 0, 0, 0, 4.05);
    touch(&pad, 1, 100, 100, 0, 5.00);
    assert(clicks(0) == 1);
    touch(&pad, 0, 0, 0, 0, 5.05);
    AKTrackpadFlush(&pad, 6.00, emit, NULL);
    assert(clicks(0) == 2 && clicks(1) == 0);

    // A pinch apart: wheel lines forward, and no click when the fingers lift.
    reset(&pad);
    touch(&pad, 2, 200, 200, 40, 7.00);
    for (int i = 1; i <= 10; i++) touch(&pad, 2, 200, 200, 40 + 6 * i, 7.00 + 0.02 * i);
    touch(&pad, 1, 200, 200, 0, 7.25);
    touch(&pad, 0, 0, 0, 0, 7.30);
    assert(scrolled() == 4 && clicks(0) + clicks(1) == 0 && !pad.tapPending);   // the first 8 points decide the gesture

    // ...and together: lines back.
    reset(&pad);
    touch(&pad, 2, 200, 200, 100, 8.00);
    for (int i = 1; i <= 10; i++) touch(&pad, 2, 200, 200, 100 - 6 * i, 8.00 + 0.02 * i);
    touch(&pad, 0, 0, 0, 0, 8.30);
    assert(scrolled() == -4);

    // Two fingers sliding together: a scroll, not a pinch.
    reset(&pad);
    touch(&pad, 2, 200, 200, 40, 9.00);
    for (int i = 1; i <= 10; i++) touch(&pad, 2, 200, 200 + 6 * i, 40, 9.00 + 0.02 * i);
    touch(&pad, 0, 0, 0, 0, 9.30);
    assert(scrolled() == 4 && !pad.pinching);

    // A two-finger tap: a right click at once.
    reset(&pad);
    touch(&pad, 2, 200, 200, 40, 10.00);
    touch(&pad, 0, 0, 0, 0, 10.10);
    assert(count == 2 && clicks(1) == 1 && !pad.tapPending);

    // A held finger: a left press, a drag, the release.
    reset(&pad);
    touch(&pad, 1, 100, 100, 0, 11.00);
    AKTrackpadHold(&pad, 11.50, emit, NULL);
    touch(&pad, 1, 140, 100, 0, 11.60);
    touch(&pad, 0, 0, 0, 0, 11.70);
    assert(count == 3 && events[0].action == AKTrackpadDown && events[1].action == AKTrackpadMove && events[2].action == AKTrackpadUp);

    puts("trackpad: taps, double taps, pinches, scrolls and drags");
    return 0;
}
