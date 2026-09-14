// Layout declarations for Apple's private MultitouchSupport.framework.
//
// The framework itself is loaded with dlopen/dlsym at runtime (see
// MultitouchReader.swift) so that a future macOS dropping or renaming it
// produces a friendly error instead of a launch-time crash. Only the struct
// layout has to be declared ahead of time, because the contact callback hands
// us a C array of MTTouch and the stride has to match exactly.
//
// This layout has been stable since ~10.5 and is the one used by every
// open-source consumer of the framework. MultitouchReader validates the values
// it reads (normalized coordinates in 0...1, state in 0...7) and reports a
// warning if the layout ever stops matching.
#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef struct {
    int frame;
    double timestamp;
    int identifier;   // stable per-finger path id for as long as it touches
    int state;        // MTTouchState, see below
    int fingerID;
    int handID;
    MTVector normalized;  // position in 0...1, origin at bottom-left
    float size;
    int zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector mm;      // position in millimetres
    int zero2[2];
    float density;
} MTTouch;

// MTTouchState values:
//   0 not tracking   1 start in range   2 hover in range   3 make touch
//   4 touching       5 breaking touch   6 linger in range  7 out of range
#define MT_STATE_MAKE_TOUCH 3
#define MT_STATE_TOUCHING 4
#define MT_STATE_BREAK_TOUCH 5

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef, MTTouch *, int, double, int);

#endif /* CMULTITOUCH_H */
