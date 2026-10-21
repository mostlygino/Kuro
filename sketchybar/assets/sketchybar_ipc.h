#pragma once

#include <stdint.h>

// Sends one SketchyBar message as a pre-built argument block: each argument
// NUL-terminated, concatenated, `length` counting every byte including those
// NULs. That is exactly the wire format SketchyBar expects, so nothing here
// parses, quotes, or splits anything.
//
// This replaced a `sketchybar_send(const char *message)` that took one space
// separated string and re-split it on unquoted whitespace, mimicking the
// official CLI helper. That round trip through a flat string was a security bug,
// not just an inelegance: see the comment in sketchybar_ipc.c.
int sketchybar_send_args(const char *buffer, uint32_t length);
