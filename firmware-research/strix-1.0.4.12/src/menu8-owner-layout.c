/* Proposed 32-bit owner tail; layout checks only, NOT patched into firmware.
 * Preconditions: every allocation is expanded before any tail access; original
 * constructor is called first; cleanup precedes original parent destruction.
 */
#include "menu8-sidecar.h"
#include "menu8-renderer.h"
#include <stddef.h>
typedef struct {
  M8 controller;
  M8Render renderer;
} M8Tail;
typedef struct { unsigned char stock[0xdc]; M8Tail extra; } M8Owner;
#if UINTPTR_MAX==0xffffffff
_Static_assert(sizeof(M8)==16,"controller ABI");
_Static_assert(sizeof(M8Tail)==32,"tail ABI");
_Static_assert(offsetof(M8Owner,extra)==0xdc,"preserve every stock field");
_Static_assert(sizeof(M8Owner)==0xfc,"proposed allocation size");
#endif
