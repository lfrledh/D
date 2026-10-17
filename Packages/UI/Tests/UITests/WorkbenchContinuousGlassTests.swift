import AppKit
import Metal
import SwiftUI
import Testing
@testable import UI

/// Actual offscreen Metal execution of the production stitchable function. This
/// does not measure desktop presentation or SwiftUI compositor frame pacing.
@Suite("Continuous D background", .serialized) @MainActor
struct WorkbenchContinuousGlassTests {
    @Test(arguments: [CGFloat(1), 2], ["rectangle22", "circle22", "continuous22", "rectangle64", "circle64", "continuous64", "rectangle160", "circle160", "continuous160", "overlap64", "neck64"])
    func productionShaderSamplesDBackgroundAtDisplayDensity(density: CGFloat, shape: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "Metal device is required; CPU comparison is not GPU evidence")
        let libraryURL = try #require(WorkbenchContinuousGlassResources.bundle.url(forResource: "default", withExtension: "metallib"))
        let shipped = try device.makeLibrary(URL: libraryURL)
        #expect(shipped.functionNames.contains("workbenchContinuousGlass"))
        let length:CGFloat = shape.hasSuffix("22") ? 22 : shape.hasSuffix("64") ? 64 : 160
        let size = CGSize(width:length,height:length*0.75), box = CGRect(origin: .zero, size: size)
        let path: CGPath
        switch shape {
        case "overlap64":
            let joined=CGMutablePath();joined.addRect(.init(x:0,y:0,width:size.width*0.65,height:size.height));joined.addRect(.init(x:size.width*0.35,y:0,width:size.width*0.65,height:size.height));path=joined
        case "neck64":
            let joined=CGMutablePath();joined.addRect(.init(x:0,y:0,width:size.width*0.4,height:size.height));joined.addRect(.init(x:size.width*0.6,y:0,width:size.width*0.4,height:size.height));joined.addRect(.init(x:0,y:size.height*0.45,width:size.width,height:size.height*0.1));path=joined
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
        var timings:[[String:Double]]=[]
        func render(origin: SIMD2<Float>, refracts: Float) throws -> [UInt8] {
            let began=ProcessInfo.processInfo.systemUptime
            var args: [SIMD4<Float>] = [.init(Float(density),Float(field.data.count),Float(field.samplingSize.width),Float(field.samplingSize.height)),
                .init(Float(size.width),Float(size.height),refracts,0), .init(origin.x,origin.y,Float(size.width),Float(size.height)), .init(0,0,256,256)]
            let command = try #require(queue.makeCommandBuffer()), encoder = try #require(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline); encoder.setTexture(output,index:0); encoder.setTexture(input,index:1)
            encoder.setBuffer(buffer,offset:0,index:0)
            args.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:1) }
            encoder.dispatchThreads(.init(width: output.width,height:output.height,depth:1), threadsPerThreadgroup:.init(width:8,height:8,depth:1)); encoder.endEncoding()
            let encoded=ProcessInfo.processInfo.systemUptime
            command.commit(); command.waitUntilCompleted()
            let completed=ProcessInfo.processInfo.systemUptime
            timings.append(["cpu_encode_ms":(encoded-began)*1000,"submit_wait_ms":(completed-encoded)*1000,
                "gpu_ms":max(0,command.gpuEndTime-command.gpuStartTime)*1000])
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
        if shape == "rectangle160" {
            let shoulder = (rowIndex:output.height/2, column:Int(6*density))
            let index = (shoulder.rowIndex*output.width+shoulder.column)*4
            #expect(Int(glass[index])-Int(plain[index]) >= 2,
                "The continuous lens must visibly displace the background, beyond the previous subpixel shoulder")
        }
        // A linear ramp must remain monotonic through the entire shoulder. This
        // detects folds and the former discrete ring transition seams.
        let row=output.height/2
        for x in 2..<output.width-2 {
            let previous=Int(glass[(row*output.width+x-1)*4]), current=Int(glass[(row*output.width+x)*4])
            #expect(current >= previous && current-previous <= 2)
        }
        if shape == "continuous160", density == 2,
           let root=ProcessInfo.processInfo.environment["D_GLASS_EVIDENCE_DIR"] {
            var groups:[String:Any]=[:]
            for optical:Float in [0,1] {
                timings=[]
                for frame in 0..<40 { _=try render(origin:.init(20+Float(frame)/8,30),refracts:optical) }
                let samples=Array(timings.dropFirst(4))
                func percentiles(_ key:String)->[String:Double] {
                    let values=samples.compactMap { $0[key] }.sorted()
                    return ["p50":values[Int(Double(values.count-1)*0.5)],"p95":values[Int(Double(values.count-1)*0.95)],"p99":values[Int(Double(values.count-1)*0.99)]]
                }
                groups[optical == 0 ? "A1_background_only" : "A3_continuous"]=["samples":samples,"cpu_encode_ms":percentiles("cpu_encode_ms"),"gpu_ms":percentiles("gpu_ms"),"submit_wait_ms":percentiles("submit_wait_ms")]
            }
            let result:[String:Any]=["kind":"offscreen-production-source-Metal-kernel-not-SwiftUI-compositor-or-desktop-FPS",
                "device":device.name,"sizePoints":[size.width,size.height],"density":density,"fieldBytes":field.data.count,
                "modelLoad":"none","sampling":"four warmup plus thirty-six serialized commands; test-only waitUntilCompleted", "groups":groups]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:root).appendingPathComponent("continuous-gpu-timing.json"))
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
    @Test func contourPreparationNeverAllocatesPanelAreaOrStarvesLaterSurfaces() throws {
        let cache=WorkbenchGlassFields();var times:[Double]=[]
        for index in 0..<192 {
            let size=CGSize(width:800+index,height:600),path=RoundedRectangle(cornerRadius:24,style:.continuous).path(in:CGRect(origin:.zero,size:size)).cgPath
            let start=ProcessInfo.processInfo.systemUptime
            let field=try #require(cache.resolve(path:path,size:size,density:2))
            times.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            #expect(field.width>=Int(size.width*2)+4 && field.data.count<128*1024)
        }
        #expect(cache.builds==192 && cache.bytes<=WorkbenchGlassFields.budget)
        if let root=ProcessInfo.processInfo.environment["D_GLASS_EVIDENCE_DIR"] {
            let sorted=times.sorted()
            try JSONSerialization.data(withJSONObject:["kind":"synchronous-contour-only-CPU-not-frame-presentation","samples_ms":times,"p50_ms":sorted[95],"p95_ms":sorted[181],"p99_ms":sorted[189],"cacheBytes":cache.bytes],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:root).appendingPathComponent("contour-resize-timing.json"))
        }
    }
}

extension WorkbenchContinuousGlassTests {
    @Test(arguments:[false,true]) func packedContourMatchesAnalyticBoundary(circle:Bool) throws {
        let size=CGSize(width:12,height:circle ? 12:8),box=CGRect(origin:.zero,size:size)
        let path=circle ? CGPath(ellipseIn:box,transform:nil):CGPath(rect:box,transform:nil)
        let field=try #require(WorkbenchGlassField.make(path:path,size:size,density:2))
        for y in stride(from:CGFloat(0.25),to:size.height,by:0.5) { for x in stride(from:CGFloat(0.25),to:size.width,by:0.5) {
            let expected=circle ? abs(hypot(x-6,y-6)-6):min(x,size.width-x,y,size.height-y)
            if expected<=min(size.width,size.height)/4+1 {
                #expect(abs(contourDistance(field,.init(x:x*2+2,y:y*2+2))/2-Float(expected))<0.07)
            }
        } }
    }
    @Test func normalizedFilledBoundaryRemovesInternalOverlapAndKeepsHole() throws {
        let joined=CGMutablePath();joined.addRect(.init(x:0,y:0,width:12,height:20));joined.addRect(.init(x:8,y:0,width:12,height:20))
        let union=try #require(WorkbenchGlassField.make(path:joined,size:.init(width:20,height:20),density:2))
        #expect(abs(contourDistance(union,.init(x:8*2+2,y:4*2+2))/2-4)<0.001)
        let hole=CGMutablePath();hole.addRect(.init(x:0,y:0,width:20,height:20))
        hole.move(to:.init(x:8,y:8));hole.addLine(to:.init(x:8,y:12));hole.addLine(to:.init(x:12,y:12));hole.addLine(to:.init(x:12,y:8));hole.closeSubpath()
        let ring=try #require(WorkbenchGlassField.make(path:hole,size:.init(width:20,height:20),density:2))
        #expect(abs(contourDistance(ring,.init(x:7*2+2,y:10*2+2))/2-1)<0.001)
    }
    private func contourDistance(_ field:WorkbenchGlassField,_ point:CGPoint)->Float {
        func word(_ i:Int)->UInt32 { field.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:i*4,as:UInt32.self) } }
        let tile=Int(word(4)),cols=Int(word(2)),rows=Int(word(3))
        let cell=min(rows-1,max(0,Int(point.y)/tile))*cols+min(cols-1,max(0,Int(point.x)/tile))
        let first=Int(word(5+cell*2)),count=Int(word(6+cell*2));var best:Float=10000
        for i in first..<first+count {
            let j=Int(word(0))+Int(word(Int(word(1))+i))*4
            let a=SIMD2<Float>(Float(bitPattern:word(j)),Float(bitPattern:word(j+1))),b=SIMD2<Float>(Float(bitPattern:word(j+2)),Float(bitPattern:word(j+3)))
            let q=SIMD2<Float>(Float(point.x),Float(point.y))-a,v=b-a
            let t=max(0,min(1,(q.x*v.x+q.y*v.y)/max(0.000001,v.x*v.x+v.y*v.y)))
            let d=q-v*t;best=min(best,sqrt(d.x*d.x+d.y*d.y))
        }
        return best
    }
}

/// Test-only GPU pixel recorder for a real native decorative consumer. It cannot
/// see the desktop, and does not claim the mixed AppKit compositor presented it.
@MainActor enum ContinuousGlassPixelProbe {
    static func pixel(_ p:WorkbenchGlassParameters) throws -> [UInt8] {
        try render(p,width:1,height:1,start:.init(x:p.size.width/2,y:p.size.height/2),step:.zero)
    }
    static func image(_ p:WorkbenchGlassParameters,density:CGFloat) throws -> CGImage {
        let w=max(1,Int(ceil(p.size.width*density))),h=max(1,Int(ceil(p.size.height*density)))
        let step=CGSize(width:p.size.width/CGFloat(w),height:p.size.height/CGFloat(h))
        let data=Data(try render(p,width:w,height:h,start:.init(x:step.width/2,y:step.height/2),step:step))
        let provider=try #require(CGDataProvider(data:data as CFData))
        return try #require(CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    private static func render(_ p:WorkbenchGlassParameters,width:Int,height:Int,start:CGPoint,step:CGSize) throws -> [UInt8] {
        let device=try #require(MTLCreateSystemDefaultDevice())
        let url=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/UI/Resources/Shaders/WorkbenchContinuousGlass.metal")
        let source=try String(contentsOf:url,encoding:.utf8)+"""
        kernel void probe(texture2d<half,access::write> out [[texture(0)]], texture2d<half> input [[texture(1)]],
        device const void *field [[buffer(0)]],constant float4 *a [[buffer(1)]],uint2 gid [[thread_position_in_grid]]) {
          if (gid.x>=out.get_width() || gid.y>=out.get_height()) return;
          out.write(workbenchContinuousGlass(a[5].zw+float2(gid)*a[6].yz,input,field,int(a[6].x),a[0].xy,a[0].zw,a[1],a[2],half4(a[3]),half4(a[4]),a[5].x,a[5].y),gid);
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
        let od=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:width,height:height,mipmapped:false);od.usage=[.shaderWrite];od.storageMode = .shared
        let out=try #require(device.makeTexture(descriptor:od))
        let buffer=try #require(p.field.data.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count) })
        func color(_ value:String) throws -> SIMD4<Float> {
            let c=try #require(NSColor(cgColor:WorkbenchLocalRenderer.color(value))?.usingColorSpace(.sRGB))
            return .init(Float(c.redComponent),Float(c.greenComponent),Float(c.blueComponent),Float(c.alphaComponent))
        }
        let map=WorkbenchLocalRenderer.mapping(image:.init(width:p.image.width,height:p.image.height),viewport:p.viewport)
        let args:[SIMD4<Float>]=[.init(Float(p.field.samplingSize.width),Float(p.field.samplingSize.height),Float(p.size.width),Float(p.size.height)),.init(Float(p.rect.minX),Float(p.rect.minY),Float(p.rect.width),Float(p.rect.height)),.init(Float(map.minX),Float(map.minY),Float(map.width),Float(map.height)),try color(p.canvas),try color(p.panel),.init(Float(p.strength),p.refraction ? 1:0,Float(start.x),Float(start.y)),.init(Float(p.field.data.count),Float(step.width),Float(step.height),0)]
        let queue=try #require(device.makeCommandQueue()),command=try #require(queue.makeCommandBuffer()),encoder=try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline);encoder.setTexture(out,index:0);encoder.setTexture(input,index:1);encoder.setBuffer(buffer,offset:0,index:0)
        args.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:1) }
        encoder.dispatchThreads(.init(width:width,height:height,depth:1),threadsPerThreadgroup:.init(width:8,height:8,depth:1));encoder.endEncoding();command.commit();command.waitUntilCompleted()
        try #require(command.status == .completed)
        var bytes=[UInt8](repeating:0,count:width*height*4)
        bytes.withUnsafeMutableBytes { out.getBytes($0.baseAddress!,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
        return bytes
    }
}

extension WorkbenchContinuousGlassTests {
    @Test(arguments:[CGFloat(1),2]) func fractionalPanelUsesExactContourExtentOnGPU(density:CGFloat) throws {
        let size=CGSize(width:801,height:600),cache=WorkbenchGlassFields()
        let field=try #require(cache.resolve(path:CGPath(rect:CGRect(origin:.zero,size:size),transform:nil),size:size,density:density))
        let device=try #require(MTLCreateSystemDefaultDevice())
        let url=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/UI/Resources/Shaders/WorkbenchContinuousGlass.metal")
        let source=try String(contentsOf:url,encoding:.utf8)+"""
        kernel void extentProbe(texture2d<float,access::write> out [[texture(0)]],device const void *field [[buffer(0)]],constant float4 *a [[buffer(1)]],uint2 gid [[thread_position_in_grid]]) {
          float2 p=float2(a[0].x/2,a[0].y-0.25);
          float scale=min(a[0].x/(a[0].z-4),a[0].y/(a[0].w-4));
          float exact=glassDistance(glassContourPosition(p,a[0].xy,a[0].zw),field,uint2(ceil(a[0].zw)),1000)*scale;
          float wrong=glassDistance(glassContourPosition(p,a[0].xy,ceil(a[0].zw)),field,uint2(ceil(a[0].zw)),1000)*scale;
          out.write(float4(exact,wrong,0,1),gid);
        }
        """
        let library=try device.makeLibrary(source:source,options:nil)
        let pipeline=try device.makeComputePipelineState(function:try #require(library.makeFunction(name:"extentProbe")))
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:1,height:1,mipmapped:false);descriptor.storageMode = .shared;descriptor.usage=[.shaderWrite]
        let output=try #require(device.makeTexture(descriptor:descriptor)),queue=try #require(device.makeCommandQueue())
        let command=try #require(queue.makeCommandBuffer()),encoder=try #require(command.makeComputeCommandEncoder())
        let buffer=try #require(field.data.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count) })
        var args=SIMD4<Float>(Float(size.width),Float(size.height),Float(field.samplingSize.width),Float(field.samplingSize.height))
        encoder.setComputePipelineState(pipeline);encoder.setTexture(output,index:0);encoder.setBuffer(buffer,offset:0,index:0)
        withUnsafeBytes(of:&args) { encoder.setBytes($0.baseAddress!,length:$0.count,index:1) }
        encoder.dispatchThreads(.init(width:1,height:1,depth:1),threadsPerThreadgroup:.init(width:1,height:1,depth:1));encoder.endEncoding();command.commit();command.waitUntilCompleted()
        try #require(command.status == .completed)
        var result=[Float](repeating:0,count:4)
        result.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:16,from:MTLRegionMake2D(0,0,1,1),mipmapLevel:0) }
        #expect(abs(result[0]-0.25)<0.001)
        #expect(abs(result[1]-0.25)>0.01,"Rounded integer extents are a real negative control")
    }
}
