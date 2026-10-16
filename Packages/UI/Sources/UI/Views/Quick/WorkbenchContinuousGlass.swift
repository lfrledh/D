import AppKit
import Metal
import SwiftUI

enum WorkbenchContinuousGlassResources { static let bundle = Bundle.module }

/// Decorative distance only. The original path still owns clipping and hit testing.
/// Fields use a padded canonical contour, so position and uniform zoom do not
/// trigger repeated rasterization. No text, media, window or desktop pixels enter it.
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

    static func make(path: CGPath, size: CGSize, density: CGFloat = 2) -> WorkbenchGlassField? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        guard density.isFinite, density > 0, max(size.width, size.height) * density <= 8192 else { return nil }
        let width = max(5, Int(ceil(size.width * density)) + 4)
        let height = max(5, Int(ceil(size.height * density)) + 4)
        var mask = [UInt8](repeating: 0, count: width * height)
        let drawn = mask.withUnsafeMutableBytes { bytes -> Bool in
            guard let c = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            c.translateBy(x: 2, y: 2); c.scaleBy(x: density, y: density)
            c.setFillColor(gray: 1, alpha: 1); c.addPath(path); c.fillPath()
            return true
        }
        guard drawn, mask.contains(where: { $0 >= 128 }) else { return nil }
        guard !Task.isCancelled else { return nil }
        let outside = distances(mask.map { $0 < 128 }, width: width, height: height)
        guard !Task.isCancelled else { return nil }
        let inside = distances(mask.map { $0 >= 128 }, width: width, height: height)
        // Keep only the optical shoulder plus a derivative/interpolation guard.
        // Interior pixels have zero displacement, so they need no field storage.
        // This is sparse geometry, not a lower-resolution rendered surface.
        // Canonical geometry can be much larger than a tiny on-screen button.
        // Cover the maximum shader shoulder (one quarter of its short axis),
        // not 12 canonical points. Add guards for normals and interpolation.
        let band = Float(ceil(min(size.width,size.height) * density / 4) + 4)
        var rows: [UInt32] = [], spans: [UInt32] = [], samples: [Float16] = []
        rows.reserveCapacity(height*2);spans.reserveCapacity(height*6)
        samples.reserveCapacity(min(width*height,Int(band)*2*(width+height)))
        let squaredLimit=(band+0.5)*(band+0.5)
        for y in 0..<height {
            let start=spans.count/3
            var x=0
            func squared(_ x:Int)->Float { let i=y*width+x;return mask[i]>=128 ? outside[i]:inside[i] }
            while x<width {
                if squared(x)>squaredLimit { x += 1;continue }
                let first=x,offset=samples.count
                repeat {
                    let distance=max(0,sqrt(squared(x))-0.5)
                    samples.append(Float16(mask[y*width+x]>=128 ? distance:-distance));x += 1
                } while x<width && squared(x)<=squaredLimit
                spans.append(UInt32(first));spans.append(UInt32(x));spans.append(UInt32(offset))
            }
            rows.append(UInt32(start));rows.append(UInt32(spans.count/3-start))
        }
        let header = [UInt32((1 + rows.count + spans.count) * 4)] + rows + spans
        var data = header.withUnsafeBytes { Data($0) }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return WorkbenchGlassField(width: width, height: height, data: data, path: path,
            referenceSize: size, density: density)
    }

    /// Separable squared Euclidean distance transform, finite sentinels avoid infinity minus infinity.
    private static func distances(_ seeds: [Bool], width: Int, height: Int) -> [Float] {
        let infinity: Float = 1e12
        var output = [Float](repeating:infinity,count:width*height)
        var input = [Float](repeating:0,count:height)
        var sites = [Int](repeating:0,count:height)
        var cuts = [Float](repeating:0,count:height+1)
        output.withUnsafeMutableBufferPointer { out in
            seeds.withUnsafeBufferPointer { seeds in
                // Exact binary one-dimensional EDT, two linear passes. No
                // per-row arrays, closures or copies in the inner loop.
                var y=0
                while y<height {
                    let base=y*width; var nearest = -width*2, x=0
                    while x<width {
                        if seeds[base+x] { nearest=x }
                        if nearest>=0 { let d=x-nearest;out[base+x]=Float(d*d) }
                        x += 1
                    }
                    nearest=width*3;x=width-1
                    while x>=0 {
                        if seeds[base+x] { nearest=x }
                        if nearest<width { let d=nearest-x;out[base+x]=min(out[base+x],Float(d*d)) }
                        x -= 1
                    }
                    y += 1
                }
            }
            input.withUnsafeMutableBufferPointer { f in
                sites.withUnsafeMutableBufferPointer { v in
                    cuts.withUnsafeMutableBufferPointer { z in
                        var x=0
                        while x<width {
                            var q=0
                            while q<height { f[q]=out[q*width+x];q += 1 }
                            var k = -1;q=0
                            while q<height {
                                if f[q]<infinity {
                                    var s = -infinity
                                    while k>=0 {
                                        let p=v[k]
                                        s=((f[q]+Float(q*q))-(f[p]+Float(p*p)))/Float(2*(q-p))
                                        if s>z[k] { break };k -= 1
                                    }
                                    k += 1;v[k]=q;z[k]=k == 0 ? -infinity:s;z[k+1]=infinity
                                }
                                q += 1
                            }
                            if k>=0 {
                                let last=k;k=0;q=0
                                while q<height {
                                    while k<last && z[k+1]<Float(q) { k += 1 }
                                    let d=q-v[k];out[q*width+x]=Float(d*d)+f[v[k]];q += 1
                                }
                            }
                            x += 1
                        }
                    }
                }
            }
        }
        return output
    }

}

/// A single serial worker prepares decorative geometry off the UI actor. No
/// inference queue, per-button device, render loop or foreground pixels are involved.
private enum WorkbenchGlassPathElement:Sendable {
    case move(CGPoint),line(CGPoint),quad(CGPoint,CGPoint),curve(CGPoint,CGPoint,CGPoint),close
    static func capture(_ path:CGPath)->[Self] {
        var values:[Self]=[]
        path.applyWithBlock { p in
            let e=p.pointee
            switch e.type {
            case .moveToPoint:values.append(.move(e.points[0]))
            case .addLineToPoint:values.append(.line(e.points[0]))
            case .addQuadCurveToPoint:values.append(.quad(e.points[0],e.points[1]))
            case .addCurveToPoint:values.append(.curve(e.points[0],e.points[1],e.points[2]))
            case .closeSubpath:values.append(.close)
            @unknown default:break
            }
        }
        return values
    }
    static func path(_ values:[Self])->CGPath {
        let path=CGMutablePath()
        for value in values {
            switch value {
            case .move(let p):path.move(to:p)
            case .line(let p):path.addLine(to:p)
            case .quad(let c,let p):path.addQuadCurve(to:p,control:c)
            case .curve(let a,let b,let p):path.addCurve(to:p,control1:a,control2:b)
            case .close:path.closeSubpath()
            }
        }
        return path
    }
}
private struct WorkbenchGlassPrepared:Sendable { let width:Int,height:Int,data:Data }
private actor WorkbenchGlassBuilder {
    static let shared=WorkbenchGlassBuilder()
    func make(_ elements:[WorkbenchGlassPathElement],size:CGSize,density:CGFloat)->WorkbenchGlassPrepared? {
        guard !Task.isCancelled,let field=WorkbenchGlassField.make(path:WorkbenchGlassPathElement.path(elements),size:size,density:density) else { return nil }
        // Only immutable numeric geometry/data cross actors; CGPath stays owned.
        return .init(width:field.width,height:field.height,data:field.data)
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

/// Window-local bounded geometry cache. Active fields remain accounted after
/// eviction. Pending requests are coalesced and cannot publish after clear().
@MainActor final class WorkbenchGlassFields {
    private struct WeakField { weak var value:WorkbenchGlassField? }
    private struct Pending {
        let key:WorkbenchGlassGeometryKey
        var listeners:[ObjectIdentifier:()->Void]
        let task:Task<Void,Never>
    }
    private var entries:[WorkbenchGlassField]=[]
    private var live:[WeakField]=[]
    private var pending:[UUID:Pending]=[:]
    private(set) var builds=0
    private(set) var bytes=0
    private(set) var peakLiveBytes=0
    var pendingCount:Int { pending.count }
    static let budget=16*1024*1024
    var liveBytes:Int { live.compactMap(\.value).reduce(0) { $0+$1.data.count } }
    func clear() {
        for job in pending.values { job.task.cancel() };pending.removeAll()
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
    /// Synchronous deterministic geometry entry for component/Metal tests.
    func resolve(path:CGPath,size:CGSize,density:CGFloat=2)->WorkbenchGlassField? {
        guard let key=WorkbenchGlassGeometryKey.make(path:path,size:size,density:density) else { return nil }
        if let field=cached(key) { return field }
        guard let field=WorkbenchGlassField.make(path:key.path,size:key.size,density:key.density) else { return nil }
        retain(field);return field
    }
    /// Production entry: cold preparation never blocks input or performs GPU waits.
    func request(path:CGPath,size:CGSize,density:CGFloat,subscriber:AnyObject,ready:@escaping ()->Void)->WorkbenchGlassField? {
        guard let key=WorkbenchGlassGeometryKey.make(path:path,size:size,density:density) else { return nil }
        if let field=cached(key) { return field }
        let listener=ObjectIdentifier(subscriber)
        if let id=pending.first(where:{$0.value.key == key})?.key {
            pending[id]?.listeners[listener]=ready;return nil
        }
        // Invisible consumers are excluded by their owner. Bound cold work as well.
        guard pending.count<128 else { return nil }
        let id=UUID()
        let elements=WorkbenchGlassPathElement.capture(key.path)
        let task=Task { [weak self] in
            let prepared=await WorkbenchGlassBuilder.shared.make(elements,size:key.size,density:key.density)
            guard !Task.isCancelled,let self,let job=self.pending.removeValue(forKey:id) else { return }
            if let prepared {
                let field=WorkbenchGlassField(width:prepared.width,height:prepared.height,data:prepared.data,path:key.path,referenceSize:key.size,density:key.density)
                self.retain(field)
                for notify in job.listeners.values { notify() }
            }
        }
        pending[id] = .init(key:key,listeners:[listener:ready],task:task)
        return nil
    }
    isolated deinit { for job in pending.values { job.task.cancel() } }
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
