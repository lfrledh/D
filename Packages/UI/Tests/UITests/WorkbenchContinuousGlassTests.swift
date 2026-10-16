import AppKit
import Metal
import SwiftUI
import Testing
@testable import UI

/// Actual offscreen Metal execution of the production stitchable function. This
/// does not measure desktop presentation or SwiftUI compositor frame pacing.
@Suite("Continuous D background", .serialized) @MainActor
struct WorkbenchContinuousGlassTests {
    @Test(arguments: [CGFloat(1), 2], ["rectangle22", "circle22", "continuous22", "rectangle64", "circle64", "continuous64", "rectangle160", "circle160", "continuous160"])
    func productionShaderSamplesDBackgroundAtDisplayDensity(density: CGFloat, shape: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "Metal device is required; CPU comparison is not GPU evidence")
        let libraryURL = try #require(WorkbenchContinuousGlassResources.bundle.url(forResource: "default", withExtension: "metallib"))
        let shipped = try device.makeLibrary(URL: libraryURL)
        #expect(shipped.functionNames.contains("workbenchContinuousGlass"))
        let length:CGFloat = shape.hasSuffix("22") ? 22 : shape.hasSuffix("64") ? 64 : 160
        let size = CGSize(width:length,height:length*0.75), box = CGRect(origin: .zero, size: size)
        let path: CGPath
        switch shape {
        case let s where s.hasPrefix("circle"): path = CGPath(ellipseIn: box, transform: nil)
        case let s where s.hasPrefix("continuous"): path = RoundedRectangle(cornerRadius: min(24,length/4), style: .continuous).path(in: box).cgPath
        default: path = CGPath(rect: box, transform: nil)
        }
        let cache=WorkbenchGlassFields()
        let field = try #require(cache.resolve(path:path,size:size,density:density))
        #expect(CGFloat(field.width-4)/size.width >= density)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI/Resources/Shaders/WorkbenchContinuousGlass.metal")
        let source = try String(contentsOf: url, encoding: .utf8) + """
        kernel void exerciseGlass(texture2d<half, access::write> output [[texture(0)]],
            texture2d<half> input [[texture(1)]], device const void *field [[buffer(0)]],
            constant float4 *args [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float2 p = (float2(gid)+0.5) / args[0].x;
            half4 value = workbenchContinuousGlass(p, input, field, int(args[0].y), args[0].zw,
                args[1].xy, args[2], args[3], half4(0.1,0.2,0.3,1), half4(0.1,0.2,0.3,1), 1, args[1].z);
            output.write(value, gid);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipelineDescriptor = MTLComputePipelineDescriptor()
        pipelineDescriptor.computeFunction = try #require(library.makeFunction(name: "exerciseGlass"))
        let links = MTLLinkedFunctions(); links.functions = [try #require(library.makeFunction(name: "workbenchContinuousGlass"))]
        pipelineDescriptor.linkedFunctions = links
        let pipeline = try device.makeComputePipelineState(descriptor:pipelineDescriptor, options:[], reflection:nil)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 256, mipmapped: false)
        descriptor.usage = [.shaderRead]; descriptor.storageMode = .shared
        let input = try #require(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: 255, count: 256*256*4)
        for y in 0..<256 { for x in 0..<256 { let i=(y*256+x)*4; pixels[i]=UInt8(x); pixels[i+1]=UInt8(y); pixels[i+2]=40 } }
        pixels.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0,0,256,256), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 1024) }
        let outDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Int(size.width*density), height: Int(size.height*density), mipmapped: false)
        outDescriptor.usage = [.shaderWrite]; outDescriptor.storageMode = .shared
        let output = try #require(device.makeTexture(descriptor: outDescriptor))
        let buffer = try #require(field.data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        let queue = try #require(device.makeCommandQueue())
        func render(origin: SIMD2<Float>, refracts: Float) throws -> [UInt8] {
            var args: [SIMD4<Float>] = [.init(Float(density),Float(field.data.count),Float(field.width),Float(field.height)),
                .init(Float(size.width),Float(size.height),refracts,0), .init(origin.x,origin.y,Float(size.width),Float(size.height)), .init(0,0,256,256)]
            let command = try #require(queue.makeCommandBuffer()), encoder = try #require(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline); encoder.setTexture(output,index:0); encoder.setTexture(input,index:1)
            encoder.setBuffer(buffer,offset:0,index:0)
            args.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:1) }
            encoder.dispatchThreads(.init(width: output.width,height:output.height,depth:1), threadsPerThreadgroup:.init(width:8,height:8,depth:1)); encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            try #require(command.status == .completed, Comment(rawValue: String(describing: command.error)))
            var values=[UInt8](repeating:0,count:output.width*output.height*4)
            values.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: output.width*4, from: MTLRegionMake2D(0,0,output.width,output.height),mipmapLevel:0) }
            return values
        }
        let plain=try render(origin:.init(20,30),refracts:0), glass=try render(origin:.init(20,30),refracts:1)
        #expect(plain != glass, "Production shader must really displace the D background")
        #expect(stride(from:3,to:glass.count,by:4).allSatisfy { glass[$0] == 255 })
        let shifted=try render(origin:.init(23,30),refracts:1)
        let center=(output.height/2*output.width+output.width/2)*4
        #expect(shifted[center] > glass[center], "Changing D sample origin changes content; no decoration-only surrogate")
        // The middle of each contour has no optical displacement.
        #expect(abs(Int(glass[center])-Int(plain[center])) <= 1)
        // A linear ramp must remain monotonic through the entire shoulder. This
        // detects folds and the former discrete ring transition seams.
        let row=output.height/2
        for x in 2..<output.width-2 {
            let previous=Int(glass[(row*output.width+x-1)*4]), current=Int(glass[(row*output.width+x)*4])
            #expect(current >= previous && current-previous <= 2)
        }
        print("CONTINUOUS_GPU shape=\(shape) density=\(density) fieldBytes=\(field.data.count) output=\(output.width)x\(output.height)")
    }

    @Test func geometryCacheAccountsForLiveFieldsAndRejectsStaleShapes() throws {
        let cache=WorkbenchGlassFields(), size=CGSize(width:800,height:600)
        let path=RoundedRectangle(cornerRadius:24,style:.continuous).path(in:CGRect(origin:.zero,size:size)).cgPath
        let one=try #require(cache.resolve(path:path,size:size,density:1))
        #expect(cache.resolve(path:path,size:size,density:1) === one && cache.builds == 1)
        let two=try #require(cache.resolve(path:path,size:size,density:2))
        #expect(one !== two && two.width >= 1604 && two.height >= 1204)
        #expect(two.data.count < two.width*two.height*2, "Sparse geometry stays below a full half-float field")
        cache.clear()
        #expect(cache.bytes == 0 && cache.liveBytes == one.data.count+two.data.count)
        #expect(cache.resolve(path:path,size:size,density:2) === two && cache.builds == 2)
        #expect(cache.resolve(path:CGMutablePath(),size:size) == nil)
    }
}

extension WorkbenchContinuousGlassTests {
    @Test func coldGeometryIsCoalescedOffUIAndClearRejectsLatePublication() async throws {
        let cache=WorkbenchGlassFields(),subscriber=NSObject(),size=CGSize(width:800,height:600)
        let path=RoundedRectangle(cornerRadius:24,style:.continuous).path(in:CGRect(origin:.zero,size:size)).cgPath
        var callbacks=0
        #expect(cache.request(path:path,size:size,density:2,subscriber:subscriber,ready:{callbacks += 1}) == nil)
        #expect(cache.request(path:path,size:size,density:2,subscriber:subscriber,ready:{callbacks += 1}) == nil)
        #expect(cache.pendingCount == 1 && cache.builds == 0)
        cache.clear()
        for _ in 0..<20 { await Task.yield() }
        #expect(cache.pendingCount == 0 && cache.builds == 0 && callbacks == 0)
        _=cache.request(path:path,size:size,density:2,subscriber:subscriber,ready:{callbacks += 1})
        for _ in 0..<300 where cache.pendingCount>0 { try await Task.sleep(for:.milliseconds(10)) }
        #expect(cache.pendingCount == 0 && cache.builds == 1 && callbacks == 1)
        let field=try #require(cache.request(path:path,size:size,density:2,subscriber:subscriber,ready:{}))
        #expect(field.width>=1604 && cache.builds == 1)
    }
}

extension WorkbenchContinuousGlassTests {
    @Test(arguments:[false,true]) func packedFieldMatchesExactRasterDistance(ellipse:Bool) throws {
        let size=CGSize(width:12,height:8),box=CGRect(origin:.zero,size:size)
        let path=ellipse ? CGPath(ellipseIn:box,transform:nil):CGPath(roundedRect:box,cornerWidth:2,cornerHeight:2,transform:nil)
        let field=try #require(WorkbenchGlassField.make(path:path,size:size,density:1))
        let w=field.width,h=field.height
        var mask=[UInt8](repeating:0,count:w*h)
        mask.withUnsafeMutableBytes { b in
            let c=CGContext(data:b.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0)!
            c.translateBy(x:2,y:2);c.setFillColor(gray:1,alpha:1);c.addPath(path);c.fillPath()
        }
        func word(_ index:Int)->UInt32 { field.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:index*4,as:UInt32.self) } }
        for y in 0..<h { for x in 0..<w {
            let inside=mask[y*w+x]>=128
            let seeds=(0..<w*h).filter { (mask[$0]>=128) != inside }
            let exact=sqrt(Float(seeds.map { let dx=x-$0%w,dy=y-$0/w;return dx*dx+dy*dy }.min()!))-0.5
            var stored:Float?
            for span in Int(word(1+y*2))..<(Int(word(1+y*2))+Int(word(2+y*2))) {
                let base=1+h*2+span*3,start=Int(word(base)),end=Int(word(base+1))
                if x>=start && x<end {
                    let offset=Int(word(0))+(Int(word(base+2))+x-start)*2
                    stored=field.data.withUnsafeBytes { Float(Float16(bitPattern:$0.loadUnaligned(fromByteOffset:offset,as:UInt16.self))) }
                }
            }
            if let stored { #expect(abs(stored-(inside ? exact:-exact)) < 0.004) }
            else { #expect(exact > Float(ceil(min(size.width,size.height)/4)+4)) }
        } }
    }
}

/// Test-only GPU pixel recorder for a real native decorative consumer. It cannot
/// see the desktop, and does not claim the mixed AppKit compositor presented it.
@MainActor enum ContinuousGlassPixelProbe {
    static func pixel(_ p:WorkbenchGlassParameters) throws -> [UInt8] {
        let device=try #require(MTLCreateSystemDefaultDevice())
        let url=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/UI/Resources/Shaders/WorkbenchContinuousGlass.metal")
        let source=try String(contentsOf:url,encoding:.utf8)+"""
        kernel void probe(texture2d<half,access::write> out [[texture(0)]], texture2d<half> input [[texture(1)]],
        device const void *field [[buffer(0)]],constant float4 *a [[buffer(1)]],uint2 gid [[thread_position_in_grid]]) {
          out.write(workbenchContinuousGlass(a[5].zw,input,field,int(a[6].x),a[0].xy,a[0].zw,a[1],a[2],half4(a[3]),half4(a[4]),a[5].x,a[5].y),gid);
        }
        """
        let library=try device.makeLibrary(source:source,options:nil),desc=MTLComputePipelineDescriptor()
        desc.computeFunction=try #require(library.makeFunction(name:"probe"))
        let linked=MTLLinkedFunctions();linked.functions=[try #require(library.makeFunction(name:"workbenchContinuousGlass"))];desc.linkedFunctions=linked
        let pipeline=try device.makeComputePipelineState(descriptor:desc,options:[],reflection:nil)
        let context=try #require(WorkbenchLocalRenderer.bitmap(width:p.image.width,height:p.image.height))
        context.draw(p.image,in:CGRect(x:0,y:0,width:p.image.width,height:p.image.height))
        let td=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:p.image.width,height:p.image.height,mipmapped:false)
        td.usage=[.shaderRead];td.storageMode = .shared
        let input=try #require(device.makeTexture(descriptor:td))
        input.replace(region:MTLRegionMake2D(0,0,td.width,td.height),mipmapLevel:0,withBytes:try #require(context.data),bytesPerRow:context.bytesPerRow)
        let od=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1,height:1,mipmapped:false);od.usage=[.shaderWrite];od.storageMode = .shared
        let out=try #require(device.makeTexture(descriptor:od))
        let buffer=try #require(p.field.data.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count) })
        func color(_ value:String) throws -> SIMD4<Float> {
            let c=try #require(NSColor(cgColor:WorkbenchLocalRenderer.color(value))?.usingColorSpace(.sRGB))
            return .init(Float(c.redComponent),Float(c.greenComponent),Float(c.blueComponent),Float(c.alphaComponent))
        }
        let map=WorkbenchLocalRenderer.mapping(image:.init(width:p.image.width,height:p.image.height),viewport:p.viewport)
        let args:[SIMD4<Float>]=[.init(Float(p.field.width),Float(p.field.height),Float(p.size.width),Float(p.size.height)),.init(Float(p.rect.minX),Float(p.rect.minY),Float(p.rect.width),Float(p.rect.height)),.init(Float(map.minX),Float(map.minY),Float(map.width),Float(map.height)),try color(p.canvas),try color(p.panel),.init(Float(p.strength),p.refraction ? 1:0,Float(p.size.width/2),Float(p.size.height/2)),.init(Float(p.field.data.count),0,0,0)]
        let queue=try #require(device.makeCommandQueue()),command=try #require(queue.makeCommandBuffer()),encoder=try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline);encoder.setTexture(out,index:0);encoder.setTexture(input,index:1);encoder.setBuffer(buffer,offset:0,index:0)
        args.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:1) }
        encoder.dispatchThreads(.init(width:1,height:1,depth:1),threadsPerThreadgroup:.init(width:1,height:1,depth:1));encoder.endEncoding();command.commit();command.waitUntilCompleted()
        try #require(command.status == .completed)
        var bytes=[UInt8](repeating:0,count:4)
        bytes.withUnsafeMutableBytes { out.getBytes($0.baseAddress!,bytesPerRow:4,from:MTLRegionMake2D(0,0,1,1),mipmapLevel:0) }
        return bytes
    }
}
