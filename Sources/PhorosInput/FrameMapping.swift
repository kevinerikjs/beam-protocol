import CoreGraphics
import Foundation

/// Geometry between the frame a client shows and the source a host captures.
/// Pure functions, no I/O.
///
/// A client sends taps and viewport locks normalised to the frame it shows
/// (0...1, origin top-left). The host encodes a fixed-aspect frame, so when
/// the source has a different aspect the picture is letterboxed inside it.
/// These functions undo the letterbox, then the viewport lock, then place the
/// result on the source.
public enum FrameMapping {
    /// The part of the frame that carries picture, normalised to the frame,
    /// when a source of `sourceSize` is fitted into a frame of `frameSize`
    /// and centred. The whole frame when the aspects match. `.null` when a
    /// size is empty.
    public static func contentRect(sourceSize: CGSize, frameSize: CGSize) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0, sourceSize.width > 0, sourceSize.height > 0 else {
            return .null
        }
        let frameAspect = frameSize.width / frameSize.height
        let sourceAspect = sourceSize.width / sourceSize.height
        if sourceAspect > frameAspect {
            let height = min(max(frameAspect / sourceAspect, 0.001), 1)
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        if sourceAspect < frameAspect {
            let width = min(max(sourceAspect / frameAspect, 0.001), 1)
            return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
        return CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// A frame-normalised rect as a source-normalised rect, with the
    /// letterbox removed and the result clipped to the source. `.null` when
    /// the rect lies entirely in the letterbox or a size is empty.
    public static func sourceRect(fromFrameRect frameRect: CGRect, sourceSize: CGSize, frameSize: CGSize) -> CGRect {
        let content = contentRect(sourceSize: sourceSize, frameSize: frameSize)
        guard !content.isNull else { return .null }
        let mapped = CGRect(
            x: (frameRect.minX - content.minX) / content.width,
            y: (frameRect.minY - content.minY) / content.height,
            width: frameRect.width / content.width,
            height: frameRect.height / content.height
        )
        let clipped = mapped.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return .null }
        return clipped
    }

    /// Where a tap lands on the source, in the source's own coordinates.
    ///
    /// - `point`: the tap, normalised to the frame the client shows.
    /// - `sourceFrame`: the captured window or display, in the coordinates
    ///   the result should use (for macOS `CGEvent`, global top-left points).
    /// - `shownViewport`: the viewport lock, normalised to the source, or
    ///   `nil` for the whole source.
    /// - `frameSize`: the encoded frame's size in pixels.
    ///
    /// `nil` when the tap is in the letterbox or a size is empty.
    public static func sourcePoint(
        forFramePoint point: CGPoint,
        sourceFrame: CGRect,
        shownViewport: CGRect?,
        frameSize: CGSize
    ) -> CGPoint? {
        guard sourceFrame.width > 0, sourceFrame.height > 0 else { return nil }
        let shown = shownViewport ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let shownPixels = CGSize(width: shown.width * sourceFrame.width, height: shown.height * sourceFrame.height)
        // The rect mapper rejects empty rects, so map a hairline and keep its origin.
        let hairline = CGRect(origin: point, size: CGSize(width: 0.001, height: 0.001))
        let mapped = sourceRect(fromFrameRect: hairline, sourceSize: shownPixels, frameSize: frameSize)
        guard !mapped.isNull else { return nil }
        let inShown = CGPoint(x: min(max(mapped.minX, 0), 1), y: min(max(mapped.minY, 0), 1))
        let inSource = CGPoint(x: shown.minX + inShown.x * shown.width, y: shown.minY + inShown.y * shown.height)
        return CGPoint(
            x: sourceFrame.minX + inSource.x * sourceFrame.width,
            y: sourceFrame.minY + inSource.y * sourceFrame.height
        )
    }
}
