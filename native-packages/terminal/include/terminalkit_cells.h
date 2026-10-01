#ifndef TERMINALKIT_CELLS_H
#define TERMINALKIT_CELLS_H
#include "terminalkit.h"

/* Native zero-copy snapshot layout. The importer only needs the opaque pointer. */
struct terminalkit_cell {
    uint32_t text_offset;
    uint32_t text_length;
    uint32_t width;
    uint32_t reserved;
    uint64_t style;
};
#endif
