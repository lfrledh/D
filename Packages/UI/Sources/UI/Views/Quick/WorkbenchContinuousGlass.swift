import AppKit
import Metal
import SwiftUI

enum WorkbenchContinuousGlassResources { static let bundle = Bundle.module }

/// Decorative distance only. The original path still owns clipping and hit testing.
/// Fields use a padded canonical contour, so position and uniform zoom do not
/// trigger repeated contour preparation. No text, media, window or desktop pixels enter it.
final class WorkbenchGlassField {
    let id = UUID()
    let width: Int
    let height: Int
    let data: Data
    let path: CGPath
    let referenceSize: CGSize
    static let padding = 2
    let density: CGFloat
    init(width: Int, height: Int, data: Data, path: CGPath, referenceSize: CGSize, density: CGFloat) {
        self.width = width; self.height = height; self.data = data; self.path = path
        self.referenceSize = referenceSize; self.density = density
    }

    /// A subpixel polyline of the filled boundary, spatially indexed. Cost follows
    /// contour complexity, never the area of a large panel or a zoomed graph.
    static func make(path: CGPath, size: CGSize, density: CGFloat = 2) -> WorkbenchGlassField? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              density.isFinite, density > 0, max(size.width,size.height)*density <= 8192 else { return nil }
        let width=max(5,Int(ceil(size.width*density))+4),height=max(5,Int(ceil(size.height*density))+4)
        var transform=CGAffineTransform(a:density,b:0,c:0,d:density,tx:2,ty:2)
        // Remove internal overlap seams using the same nonzero fill as the real clip.
        guard let boundary=path.normalized(using:.winding).copy(using:&transform),!boundary.isEmpty else { return nil }
        var segments:[SIMD4<Float>]=[],current=CGPoint.zero,start=CGPoint.zero,valid=true
        func distance(_ p:CGPoint,_ a:CGPoint,_ b:CGPoint)->CGFloat {
            let dx=b.x-a.x,dy=b.y-a.y,n=dx*dx+dy*dy
            let t=n>0 ? max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/n)):0
            return hypot(p.x-a.x-t*dx,p.y-a.y-t*dy)
        }
        func line(_ a:CGPoint,_ b:CGPoint) {
            guard valid else { return }
            guard [a.x,a.y,b.x,b.y].allSatisfy(\.isFinite),segments.count<16384 else { valid=false;return }
            if a != b { segments.append(.init(Float(a.x),Float(a.y),Float(b.x),Float(b.y))) }
        }
        func mid(_ a:CGPoint,_ b:CGPoint)->CGPoint { .init(x:(a.x+b.x)/2,y:(a.y+b.y)/2) }
        func cubic(_ a:CGPoint,_ b:CGPoint,_ c:CGPoint,_ d:CGPoint,_ depth:Int=0) {
            guard valid else { return }
            if max(distance(b,a,d),distance(c,a,d))<=0.125 { line(a,d);return }
            guard depth<20 else { valid=false;return }
            let ab=mid(a,b),bc=mid(b,c),cd=mid(c,d),abc=mid(ab,bc),bcd=mid(bc,cd),center=mid(abc,bcd)
            cubic(a,ab,abc,center,depth+1);cubic(center,bcd,cd,d,depth+1)
        }
        boundary.applyWithBlock { item in
            let e=item.pointee
            switch e.type {
            case .moveToPoint:current=e.points[0];start=current
            case .addLineToPoint:line(current,e.points[0]);current=e.points[0]
            case .addQuadCurveToPoint:
                let c=e.points[0],d=e.points[1]
                cubic(current,.init(x:current.x+(c.x-current.x)*2/3,y:current.y+(c.y-current.y)*2/3),.init(x:d.x+(c.x-d.x)*2/3,y:d.y+(c.y-d.y)*2/3),d);current=d
            case .addCurveToPoint:cubic(current,e.points[0],e.points[1],e.points[2]);current=e.points[2]
            case .closeSubpath:line(current,start);current=start
            @unknown default:valid=false
            }
        }
        guard valid,!segments.isEmpty else { return nil }
        let tile=max(16,Int(ceil(min(size.width,size.height)*density/8)))
        let cols=(width+tile-1)/tile,rows=(height+tile-1)/tile
        guard cols*rows<=65536 else { return nil }
        // Conservative for every scale sharing this canonical contour. Includes
        // the ±1px normal samples and flattening error, across cell boundaries.
        let band=Float(min(size.width,size.height)*density/4+4)
        var cells=[[UInt32]](repeating:[],count:cols*rows),references=0
        for (index,v) in segments.enumerated() {
            let x0=max(0,min(cols-1,Int(floor((min(v.x,v.z)-band)/Float(tile)))))
            let x1=max(0,min(cols-1,Int(floor((max(v.x,v.z)+band)/Float(tile)))))
            let y0=max(0,min(rows-1,Int(floor((min(v.y,v.w)-band)/Float(tile)))))
            let y1=max(0,min(rows-1,Int(floor((max(v.y,v.w)+band)/Float(tile)))))
            for y in y0...y1 { for x in x0...x1 { cells[y*cols+x].append(UInt32(index));references += 1 } }
            // Unusually complex contours use an exact full-list query instead
            // of truncating geometry. Normal D contours use the spatial index.
            if references>1_000_000 { break }
        }
        let useFullList=references>1_000_000
        if useFullList { cells=[Array(segments.indices.map(UInt32.init))] }
        let count=cells.count,segmentOffset=(5+count*2+3) & ~3,indexOffset=segmentOffset+segments.count*4
        var words:[UInt32]=[UInt32(segmentOffset),UInt32(indexOffset),UInt32(useFullList ? 1:cols),UInt32(useFullList ? 1:rows),UInt32(useFullList ? max(width,height):tile)]
        var offset=0
        for cell in cells { words.append(UInt32(offset));words.append(UInt32(cell.count));offset += cell.count }
        while words.count<segmentOffset { words.append(0) }
        for v in segments { words += [v.x.bitPattern,v.y.bitPattern,v.z.bitPattern,v.w.bitPattern] }
        for cell in cells { words += cell }
        return .init(width:width,height:height,data:words.withUnsafeBytes { Data($0) },path:path,referenceSize:size,density:density)
    }
}

private struct WorkbenchGlassGeometryKey:Equatable {
    let path:CGPath
    let size:CGSize
    let density:CGFloat
    func matches(_ field:WorkbenchGlassField)->Bool {
        path == field.path && abs(size.width-field.referenceSize.width)<0.001 && abs(size.height-field.referenceSize.height)<0.001 && density == field.density
    }
    static func make(path:CGPath,size:CGSize,density:CGFloat)->Self? {
        guard size.width>0,size.height>0,size.width.isFinite,size.height.isFinite,density.isFinite,density>0 else { return nil }
        let factor=256/max(size.width,size.height)
        let canonical=CGSize(width:size.width*factor,height:size.height*factor)
        var transform=CGAffineTransform(scaleX:factor,y:factor)
        guard let scaled=path.copy(using:&transform) else { return nil }
        let normalized=CGMutablePath()
        scaled.applyWithBlock { item in
            func point(_ i:Int)->CGPoint { let p=item.pointee.points[i];return CGPoint(x:(p.x*4096).rounded()/4096,y:(p.y*4096).rounded()/4096) }
            switch item.pointee.type {
            case .moveToPoint:normalized.move(to:point(0))
            case .addLineToPoint:normalized.addLine(to:point(0))
            case .addQuadCurveToPoint:normalized.addQuadCurve(to:point(1),control:point(0))
            case .addCurveToPoint:normalized.addCurve(to:point(2),control1:point(0),control2:point(1))
            case .closeSubpath:normalized.closeSubpath()
            @unknown default:break
            }
        }
        // Freeze the mutable path before crossing actors.
        guard let frozen=normalized.copy() else { return nil }
        return .init(path:frozen,size:canonical,density:pow(2,ceil(log2(max(0.25,density/factor)))))
    }
}

/// Window-local bounded contour cache. Active geometry remains accounted after eviction.
@MainActor final class WorkbenchGlassFields {
    private struct WeakField { weak var value:WorkbenchGlassField? }
    private var entries:[WorkbenchGlassField]=[]
    private var live:[WeakField]=[]
    private(set) var builds=0
    private(set) var bytes=0
    private(set) var peakLiveBytes=0
    static let budget=16*1024*1024
    var liveBytes:Int { live.compactMap(\.value).reduce(0) { $0+$1.data.count } }
    func clear() {
        entries.removeAll();bytes=0;live.removeAll { $0.value == nil }
    }
    private func cached(_ key:WorkbenchGlassGeometryKey)->WorkbenchGlassField? {
        if let index=entries.firstIndex(where:key.matches) { let field=entries.remove(at:index);entries.append(field);return field }
        return live.compactMap(\.value).first(where:key.matches)
    }
    private func retain(_ field:WorkbenchGlassField) {
        builds += 1;live.removeAll { $0.value == nil };live.append(.init(value:field))
        peakLiveBytes=max(peakLiveBytes,liveBytes)
        while bytes+field.data.count>Self.budget,!entries.isEmpty { bytes -= entries.removeFirst().data.count }
        if field.data.count<=Self.budget { entries.append(field);bytes += field.data.count }
    }
    /// Small contour-only preparation; no pixel raster, EDT or GPU wait.
    func resolve(path:CGPath,size:CGSize,density:CGFloat=2)->WorkbenchGlassField? {
        guard let key=WorkbenchGlassGeometryKey.make(path:path,size:size,density:density) else { return nil }
        if let field=cached(key) { return field }
        guard let field=WorkbenchGlassField.make(path:key.path,size:key.size,density:key.density) else { return nil }
        retain(field);return field
    }
}

struct WorkbenchGlassParameters {
    let image: CGImage
    let field: WorkbenchGlassField
    let size: CGSize
    let rect: CGRect
    let viewport: CGSize
    let canvas: String
    let panel: String
    let strength: Double
    let refraction: Bool
    func matches(_ other: Self) -> Bool {
        image === other.image && field.id == other.field.id && size == other.size && rect == other.rect
            && viewport == other.viewport && canvas == other.canvas && panel == other.panel
            && strength == other.strength && refraction == other.refraction
    }
    var shader: Shader {
        let mapping = WorkbenchLocalRenderer.mapping(image: .init(width: image.width, height: image.height), viewport: viewport)
        return ShaderLibrary.bundle(.module).workbenchContinuousGlass(
            .image(Image(decorative: image, scale: 1)), .data(field.data),
            .float2(Float(field.width), Float(field.height)), .float2(size.width, size.height),
            .float4(rect.minX, rect.minY, rect.width, rect.height),
            .float4(mapping.minX, mapping.minY, mapping.width, mapping.height),
            .color(Color(cgColor: WorkbenchLocalRenderer.color(canvas))),
            .color(Color(cgColor: WorkbenchLocalRenderer.color(panel))),
            .float(strength), .float(refraction ? 1 : 0))
    }
}

struct WorkbenchGlassDrawing: View {
    let parameters: WorkbenchGlassParameters
    var body: some View {
        Rectangle().fill(parameters.shader)
            .frame(width: parameters.size.width, height: parameters.size.height)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A stable background-only host; never hosts a node, editor, player or asset.
@MainActor final class WorkbenchGlassHost: NSHostingView<WorkbenchGlassDrawing> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// Readability remains above the optical background, below all actual content.
@MainActor final class WorkbenchGlassProtection: NSView {
    weak var source: WorkbenchBackgroundNSView?
    var effect = WorkbenchReadabilityRegistry.Effect.none { didSet { if oldValue != effect { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let source, let c = NSGraphicsContext.current?.cgContext else { return }
        WorkbenchReadabilityRegistry.paint(effect, in: c, view: source)
    }
}
