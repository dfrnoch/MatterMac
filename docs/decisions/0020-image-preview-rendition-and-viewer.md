# 0020 — Preview rendition for thumbnails, in-memory image viewer

Date: 2026-09-25. Status: implemented.

Timeline thumbnails were fetched from `/files/{id}/thumbnail` (Mattermost's small
~120 px rendition) and capped at 512 px, so a 360 pt thumbnail was blurry on
Retina and images could not be viewed larger.

Thumbnails now use `/files/{id}/preview` when the server reports
`has_preview_image` (else the thumbnail), downsampled to 360 pt × backing scale
(720 px on Retina). Clicking an image, Space on its selected row, or an
accessibility press opens a viewer window with the same preview rendition
downsampled to the screen's longest edge, at most 2048 px. The original file is
never fetched for display (SPEC §14), so the viewer is limited to the server's
preview resolution; "Save…" uses the existing explicit download path. There is no
Quick Look, temporary file, disk cache, or window restoration.

To fit both sizes into the unchanged 32 MiB decoded-image budget, the pipeline no
longer reserves a fixed 4 MiB per decode (which also capped the edge at 512 px).
It reads the source dimensions and bit depth first and reserves the downsampled
output's conservative size (4 or 8 bytes per pixel, one pixel of rounding per
edge, 64 bytes of row alignment per row), then checks the real `bytesPerRow ×
height` against it. `maximumImagePixelDimension` is now 2048 and
`maximumDecodedImageBytes` 17 MiB (a 2048 × 2048 four-byte bitmap plus
allowance). A 720 × 480 thumbnail costs about 1.4 MiB, so many visible
thumbnails leave less room for the viewer; when the budget is saturated by
displayed images the viewer shows an honest failure state instead of evicting
visible content. The viewer's lease is released when it closes or the pane
changes channel.
