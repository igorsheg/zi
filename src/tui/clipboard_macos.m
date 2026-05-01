#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static NSData *zi_png_data_from_image(NSImage *image) {
    if (image == nil) return nil;

    NSData *tiff_data = [image TIFFRepresentation];
    if (tiff_data == nil) return nil;

    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff_data];
    if (rep == nil) return nil;

    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

bool zi_clipboard_read_png(uint8_t **out_bytes, size_t *out_len) {
    if (out_bytes == NULL || out_len == NULL) return false;
    *out_bytes = NULL;
    *out_len = 0;

    @autoreleasepool {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        NSImage *image = [[NSImage alloc] initWithPasteboard:pasteboard];
        NSData *png_data = zi_png_data_from_image(image);

        if (png_data == nil || [png_data length] == 0) return false;

        size_t len = [png_data length];
        uint8_t *bytes = (uint8_t *)malloc(len);
        if (bytes == NULL) return false;

        memcpy(bytes, [png_data bytes], len);
        *out_bytes = bytes;
        *out_len = len;
        return true;
    }
}

void zi_clipboard_free(void *ptr) {
    free(ptr);
}
