// Emits the vector sources (`sources` command) from the model, as fixed-precision
// SVG text and the Icon Composer manifest, so reruns are byte-identical.

import Foundation

/// Fixed precision with trailing zeros dropped, so output is short and stable.
func svgNumber(_ value: Double) -> String {
    var text = String(format: "%.\(SVGFormat.fractionDigits)f", value)
    while text.contains("."), text.hasSuffix("0") {
        text.removeLast()
    }
    if text.hasSuffix(".") {
        text.removeLast()
    }
    return text == "-0" ? "0" : text
}

/// Square document with a matching viewBox, so AppKit and Icon Composer agree on its size.
func svgDocument(size: Double, body: [String]) -> String {
    let side = svgNumber(size)
    let header = "<svg xmlns=\"\(SVGFormat.namespace)\" width=\"\(side)\" height=\"\(side)\" viewBox=\"0 0 \(side) \(side)\">"
    return ([header] + body + ["</svg>"]).joined(separator: "\n") + "\n"
}

/// The body; one emitter, so the app and menu marks share its number format.
func ellipseSVG(_ ellipse: Ellipse, color: RGBColor) -> String {
    "<ellipse cx=\"\(svgNumber(ellipse.center.x))\" cy=\"\(svgNumber(ellipse.center.y))\" rx=\"\(svgNumber(ellipse.radiusX))\" ry=\"\(svgNumber(ellipse.radiusY))\" fill=\"\(color.svg)\"/>"
}

/// Both wrapper ends from one authored end, so they cannot drift apart.
func wrapperSVG(_ fan: Fan, color: RGBColor) -> String {
    [fan, fan.mirrored(acrossX: Bonbon.center.x)].map { end in
        let d = "M\(svgPoint(end.tip)) L\(svgPoint(end.outerTop)) Q\(svgPoint(end.pinch)) \(svgPoint(end.outerBottom)) Z"
        return "<path d=\"\(d)\" fill=\"\(color.svg)\"/>"
    }.joined(separator: "\n")
}

/// All stripes in one path, so they share one stroke and paint as one layer.
func stripesSVG(_ stripes: [Segment], width: Double, color: RGBColor) -> String {
    let d = stripes.map { "M\(svgPoint($0.from)) L\(svgPoint($0.to))" }.joined(separator: " ")
    return "<path d=\"\(d)\" fill=\"none\" stroke=\"\(color.svg)\" stroke-width=\"\(svgNumber(width))\" stroke-linecap=\"round\"/>"
}

/// `x y` with the shared number format.
func svgPoint(_ point: Point) -> String {
    "\(svgNumber(point.x)) \(svgNumber(point.y))"
}

/// Wraps drawing-unit content in one transform group, so every shape keeps its
/// authored coordinates. Scale first, then the candy's tilt about the drawing
/// center, so every layer rotates about the same point and the parts stay aligned.
func candyGroup(scale: Double, content: String) -> [String] {
    let tilt = "rotate(\(svgNumber(Bonbon.tiltDegrees)) \(svgNumber(Bonbon.center.x)) \(svgNumber(Bonbon.center.y)))"
    return ["<g transform=\"scale(\(svgNumber(scale))) \(tilt)\">", content, "</g>"]
}

/// One app-icon layer on the full canvas; the fill is the manifest's solid, not a layer.
func canvasLayerSVG(_ content: String) -> String {
    svgDocument(size: Canvas.size, body: candyGroup(scale: Canvas.scale, content: content))
}

/// The menu mark in the drawing, in template black only.
func menuSVG() -> String {
    let content = [wrapperSVG(MenuMark.wrapper, color: Palette.template), ellipseSVG(MenuMark.body, color: Palette.template)].joined(separator: "\n")
    return svgDocument(size: Bonbon.drawingSize, body: candyGroup(scale: MenuMark.scale, content: content))
}

/// Mirrors the `icon.json` layout Icon Composer reads; keys are fixed by that format.
struct IconDocument: Encodable {
    let fill: IconFill
    let groups: [IconGroup]
    let supportedPlatforms: IconPlatforms

    /// Icon Composer uses kebab-case keys.
    enum CodingKeys: String, CodingKey {
        case fill, groups
        case supportedPlatforms = "supported-platforms"
    }
}

/// The solid background that macOS clips to the icon shape.
struct IconFill: Encodable {
    let solid: String
}

/// One group holds every layer: the shape probed with `ictool` and `actool`.
struct IconGroup: Encodable {
    let layers: [IconLayerEntry]
}

/// A layer that points at one SVG in `Assets`.
struct IconLayerEntry: Encodable {
    let imageName: String
    let name: String

    /// Icon Composer uses kebab-case keys.
    enum CodingKeys: String, CodingKey {
        case imageName = "image-name"
        case name
    }
}

/// Limits the document to macOS, the only platform SweetMX ships on.
struct IconPlatforms: Encodable {
    let squares: [String]
}

/// Builds the manifest from the same constants as the layers, so names and colors cannot drift.
func iconManifestJSON() throws -> Data {
    let alpha = String(format: "%.\(IconManifest.componentDigits)f", IconManifest.alpha)
    let solid = "\(IconManifest.colorSpace):\(Palette.fill.manifest(digits: IconManifest.componentDigits)),\(alpha)"
    let layers = IconLayer.manifestOrder.map { IconLayerEntry(imageName: $0.fileName, name: $0.rawValue) }
    let document = IconDocument(fill: .init(solid: solid), groups: [.init(layers: layers)], supportedPlatforms: .init(squares: [IconManifest.platform]))
    let encoder = JSONEncoder()
    // Sorted keys keep the file stable across runs and Foundation releases.
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        return try encoder.encode(document) + Data("\n".utf8)
    } catch {
        throw RenderFailure.writeFailed(path: OutputPath.iconManifest, cause: error)
    }
}
