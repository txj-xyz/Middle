#include "include/CMultitouch.h"

// SwiftPM requires at least one source file in a C target. This also gives us a
// compile-time record of the struct size the Swift side expects.
const int CMultitouchTouchStride = (int)sizeof(MTTouch);
