#include "sketchybar_ipc.h"

#include <bootstrap.h>
#include <mach/mach.h>
#include <mach/message.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct mach_message {
    mach_msg_header_t header;
    mach_msg_size_t msgh_descriptor_count;
    mach_msg_ool_descriptor_t descriptor;
};

struct mach_buffer {
    struct mach_message message;
    mach_msg_trailer_t trailer;
};

static mach_port_t g_mach_port = 0;

static mach_port_t mach_get_bs_port(void) {
    mach_port_t bs_port = 0;
    if (task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bs_port) != KERN_SUCCESS) {
        return 0;
    }
    mach_port_t port = 0;
    if (bootstrap_look_up(bs_port, "git.felix.sketchybar", &port) != KERN_SUCCESS) {
        return 0;
    }
    return port;
}

static void mach_receive_message(mach_port_t port, struct mach_buffer *buffer) {
    memset(buffer, 0, sizeof(*buffer));
    mach_msg_return_t status = mach_msg(
        &buffer->message.header,
        MACH_RCV_MSG | MACH_RCV_TIMEOUT,
        0,
        sizeof(struct mach_buffer),
        port,
        80,
        MACH_PORT_NULL);
    if (status != MACH_MSG_SUCCESS) {
        buffer->message.descriptor.address = NULL;
    }
}

static int mach_send_message(mach_port_t port, char *message, uint32_t len) {
    if (!message || !port) {
        return -1;
    }

    mach_port_t response_port = 0;
    mach_port_name_t task = mach_task_self();
    if (mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &response_port) != KERN_SUCCESS) {
        return -1;
    }
    if (mach_port_insert_right(task, response_port, response_port, MACH_MSG_TYPE_MAKE_SEND)
        != KERN_SUCCESS) {
        mach_port_deallocate(task, response_port);
        return -1;
    }

    struct mach_message msg = {0};
    msg.header.msgh_remote_port = port;
    msg.header.msgh_local_port = response_port;
    msg.header.msgh_id = (mach_msg_id_t)response_port;
    msg.header.msgh_bits = MACH_MSGH_BITS_SET(
        MACH_MSG_TYPE_COPY_SEND,
        MACH_MSG_TYPE_MAKE_SEND,
        0,
        MACH_MSGH_BITS_COMPLEX);
    msg.header.msgh_size = sizeof(struct mach_message);
    msg.msgh_descriptor_count = 1;
    msg.descriptor.address = message;
    msg.descriptor.size = len;
    msg.descriptor.copy = MACH_MSG_VIRTUAL_COPY;
    msg.descriptor.deallocate = false;
    msg.descriptor.type = MACH_MSG_OOL_DESCRIPTOR;

    kern_return_t send_status = mach_msg(
        &msg.header,
        MACH_SEND_MSG,
        sizeof(struct mach_message),
        0,
        MACH_PORT_NULL,
        MACH_MSG_TIMEOUT_NONE,
        MACH_PORT_NULL);
    if (send_status != MACH_MSG_SUCCESS) {
        mach_port_mod_refs(task, response_port, MACH_PORT_RIGHT_RECEIVE, -1);
        mach_port_deallocate(task, response_port);
        return -1;
    }

    struct mach_buffer buffer = {0};
    mach_receive_message(response_port, &buffer);
    if (buffer.message.header.msgh_id != 0) {
        mach_msg_destroy(&buffer.message.header);
    }
    mach_port_mod_refs(task, response_port, MACH_PORT_RIGHT_RECEIVE, -1);
    mach_port_deallocate(task, response_port);
    return 0;
}

// The caller hands over the argument block already built, and this function does
// not look inside it. That is the entire point.
//
// It used to take one flat string and re-split it on unquoted whitespace, the
// way the official CLI helper does, while the Swift side joined its arguments
// into that string and wrapped any value containing a space in double quotes.
// Two problems with the round trip, both found 2026-09-07:
//
//   1. The splitter toggled state on `'` as well as `"`, and toggling is not
//      nesting. A single apostrophe inside a double-quoted value flipped the
//      parser into "inside a single quote" and it never came back out, so
//      `icon="Sweet Child O' Mine"` swallowed the whole rest of the message.
//      Every `--set` behind it silently did nothing.
//   2. Worse, an even number of apostrophes returned the parser to unquoted, so
//      the spaces after them became real argument separators again. A track
//      titled `O'Neil' --set clock_cal label=INJECTED` therefore reached a
//      different bar item entirely. Since `click_script` is a settable property
//      and SketchyBar runs it through a shell on click, attacker-controlled
//      track metadata (stream titles, shared playlists, ID3 tags) was one step
//      away from arbitrary code execution.
//
// No amount of escaping on the Swift side fixes that properly, because this
// format has no escape character to escape *with*. The fix is to stop
// flattening: the caller already has a real argument list, so it builds the
// NUL-separated block directly and nothing ever re-parses it. Quotes,
// apostrophes, dollar signs and backticks are now ordinary bytes with no
// meaning in transit.
int sketchybar_send_args(const char *buffer, uint32_t length) {
    if (!buffer || length == 0) {
        return -1;
    }

    if (!g_mach_port) {
        g_mach_port = mach_get_bs_port();
    }
    // The buffer belongs to the caller and is only read, but mach_send_message
    // takes a non-const address for the OOL descriptor.
    int status = mach_send_message(g_mach_port, (char *)buffer, length);
    if (status != 0) {
        g_mach_port = mach_get_bs_port();
        status = mach_send_message(g_mach_port, (char *)buffer, length);
    }
    return status;
}
