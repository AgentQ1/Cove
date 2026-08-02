//
//  AvatarCropView.swift
//  Inditalk
//
//  "Move and Scale" for the profile photo. A picked or captured image is almost never
//  square and almost never framed on the face, so dropping it straight into a circular
//  avatar crops it arbitrarily — this is the step that lets you decide what is kept.
//
//  The crop is computed against the SOURCE pixels (not the on-screen preview), so the
//  saved photo is full quality rather than a screen-resolution grab.
//

import SwiftUI

struct AvatarCropView: View {
    let image: UIImage
    /// The square, cropped result. Only called on "Choose".
    let onComplete: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var gestureOffset: CGSize = .zero

    /// Zooming out past "fills the circle" would show empty corners; 6x is past the
    /// point where any real photo still holds up.
    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 6
    /// Longest side of the saved avatar. Plenty for every avatar size the app renders,
    /// and keeps the upload small.
    private let outputSize: CGFloat = 1024

    private var currentScale: CGFloat { scale * gestureScale }
    private var currentOffset: CGSize {
        CGSize(width: offset.width + gestureOffset.width,
               height: offset.height + gestureOffset.height)
    }

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height) - 48
            ZStack {
                Color.black.ignoresSafeArea()

                imageLayer(diameter: diameter)
                mask(diameter: diameter, in: proxy.size)
                chrome(diameter: diameter)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                // Pan and pinch together, the way the system's own editor behaves.
                DragGesture()
                    .onChanged { gestureOffset = $0.translation }
                    .onEnded { _ in
                        offset = clamped(currentOffset, diameter: diameter)
                        gestureOffset = .zero
                    }
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { gestureScale = $0.magnification }
                        .onEnded { _ in
                            scale = min(max(currentScale, minScale), maxScale)
                            gestureScale = 1
                            // A zoom can pull the image off the crop circle; pull it back.
                            offset = clamped(offset, diameter: diameter)
                        })
            )
        }
        .statusBarHidden()
    }

    // MARK: Layers

    private func imageLayer(diameter: CGFloat) -> some View {
        let fitted = displaySize(diameter: diameter)
        return Image(uiImage: image)
            .resizable()
            .frame(width: fitted.width, height: fitted.height)
            .scaleEffect(currentScale)
            .offset(currentOffset)
    }

    /// Dim everything outside the circle so the crop is unmistakable.
    private func mask(diameter: CGFloat, in size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.6)
                .mask {
                    Rectangle()
                        .overlay(Circle().frame(width: diameter, height: diameter).blendMode(.destinationOut))
                        .compositingGroup()
                }
            Circle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                .frame(width: diameter, height: diameter)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func chrome(diameter: CGFloat) -> some View {
        VStack {
            Text("Move and Scale")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 24)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(.white)
                Spacer()
                Button("Choose") { choose(diameter: diameter) }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    // MARK: Geometry

    /// The image laid out to FILL the crop circle at scale 1 — the baseline every
    /// gesture is relative to.
    private func displaySize(diameter: CGFloat) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return CGSize(width: diameter, height: diameter) }
        let fill = max(diameter / size.width, diameter / size.height)
        return CGSize(width: size.width * fill, height: size.height * fill)
    }

    /// Keep the crop circle inside the image — panning must never expose a bare edge.
    private func clamped(_ offset: CGSize, diameter: CGFloat) -> CGSize {
        let displayed = displaySize(diameter: diameter)
        let limitX = max(0, (displayed.width * currentScale - diameter) / 2)
        let limitY = max(0, (displayed.height * currentScale - diameter) / 2)
        return CGSize(width: min(max(offset.width, -limitX), limitX),
                      height: min(max(offset.height, -limitY), limitY))
    }

    // MARK: Cropping

    private func choose(diameter: CGFloat) {
        let cropped = Self.crop(image, diameter: diameter, scale: currentScale,
                                offset: clamped(currentOffset, diameter: diameter),
                                maxSide: outputSize)
        onComplete(cropped ?? image)
        dismiss()
    }

    /// Map the on-screen transform back onto the source pixels and cut the square out.
    ///
    /// `static` and parameterised so the maths is testable without a view.
    static func crop(_ image: UIImage, diameter: CGFloat, scale: CGFloat,
                     offset: CGSize, maxSide: CGFloat) -> UIImage? {
        // EXIF-rotated photos must be baked flat first: CGImage.cropping ignores
        // `imageOrientation`, so cropping a sideways photo would cut the wrong region.
        let source = normalized(image)
        guard let cg = source.cgImage, source.size.width > 0, source.size.height > 0 else { return nil }

        let fill = max(diameter / source.size.width, diameter / source.size.height)
        let effective = fill * scale                       // source points -> screen points
        let displayed = CGSize(width: source.size.width * effective,
                               height: source.size.height * effective)

        // The crop square in displayed-point space, then converted to source pixels.
        let originX = (displayed.width - diameter) / 2 - offset.width
        let originY = (displayed.height - diameter) / 2 - offset.height
        let toPixels = source.scale / effective

        let pixelRect = CGRect(x: originX * toPixels, y: originY * toPixels,
                               width: diameter * toPixels, height: diameter * toPixels)
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1,
              let cut = cg.cropping(to: pixelRect.integral) else { return nil }

        let square = UIImage(cgImage: cut, scale: source.scale, orientation: .up)
        return downscaled(square, maxSide: maxSide)
    }

    /// Redraw with `.up` orientation so pixel coordinates mean what they say.
    private static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let target = CGSize(width: image.size.width / side * maxSide,
                            height: image.size.height / side * maxSide)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
