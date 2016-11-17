import PlaygroundSupport
import Cocoa
import Metal

/// A view which is backed by a CAMetalLayer, automatically updating its drawableSize and contentsScale as appropriate.
public class MetalView: NSView
{
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }
    
    public let metalLayer = CAMetalLayer()
    public weak var delegate: MetalViewDelegate?
    
    public init(frame: CGRect, device: MTLDevice) {
        super.init(frame: frame)
        metalLayer.device = device
        wantsLayer = true
        updateDrawableSize(contentsScale: metalLayer.contentsScale)
    }
    
    public override func makeBackingLayer() -> CALayer {
        return metalLayer
    }
    
    public override func layer(_ layer: CALayer, shouldInheritContentsScale newScale: CGFloat, from window: NSWindow) -> Bool {
        updateDrawableSize(contentsScale: newScale)
        return true
    }
    
    private func updateDrawableSize(contentsScale scale: CGFloat) {
        var size = metalLayer.bounds.size
        size.width *= scale
        size.height *= scale
        metalLayer.drawableSize = size
        delegate?.metalViewDrawableSizeDidChange(self)
    }
}


public protocol MetalViewDelegate: class
{
    func metalViewDrawableSizeDidChange(_ metalView: MetalView)
}


extension MTLSize
{
    var hasZeroDimension: Bool {
        return depth == 0 || width == 0 || height == 0
    }
}


/// Encapsulates the sizes to be passed to `MTLComputeCommandEncoder.dispatchThreadgroups(_:threadsPerThreadgroup:)`.
public struct ThreadgroupSizes
{
    var threadsPerThreadgroup: MTLSize
    var threadgroupsPerGrid: MTLSize
    
    public static let zeros = ThreadgroupSizes(
        threadsPerThreadgroup: MTLSize(),
        threadgroupsPerGrid: MTLSize())
    
    var hasZeroDimension: Bool {
        return threadsPerThreadgroup.hasZeroDimension || threadgroupsPerGrid.hasZeroDimension
    }
}



public extension MTLCommandQueue
{
    /// Helper function for running compute kernels and displaying the output onscreen.
    ///
    /// This function configures a MTLComputeCommandEncoder by setting the given `drawable`'s texture
    /// as the 0th texture (so it will be available as a `[[texture(0)]]` parameter in the kernel).
    /// It calls `drawBlock` to allow further configuration, then dispatches the threadgroups and
    /// presents the results.
    ///
    /// - Requires: `drawBlock` must call `setComputePipelineState` on the command encoder to select a compute function.
    func computeAndDraw(into drawable: @autoclosure () -> CAMetalDrawable?, with threadgroupSizes: ThreadgroupSizes, drawBlock: (MTLComputeCommandEncoder) -> Void)
    {
        if threadgroupSizes.hasZeroDimension {
            print("dimensions are zero; not drawing")
            return
        }
        
        autoreleasepool {  // Ensure drawables are freed for the system to allocate new ones.
            guard let drawable = drawable() else {
                print("no drawable")
                return
            }
            
            let buffer = self.makeCommandBuffer()
            let encoder = buffer.makeComputeCommandEncoder()
            encoder.setTexture(drawable.texture, at: 0)
            
            drawBlock(encoder)
            
            encoder.dispatchThreadgroups(threadgroupSizes.threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSizes.threadsPerThreadgroup)
            encoder.endEncoding()
            
            buffer.present(drawable)
            buffer.commit()
            buffer.waitUntilCompleted()
        }
    }
}


public extension MTLComputePipelineState
{
    /// Selects "reasonable" values for threadsPerThreadgroup and threadgroupsPerGrid for the given `drawableSize`.
    /// - Remark: The heuristics used here are not perfect. There are many ways to underutilize the GPU,
    /// including selecting suboptimal threadgroup sizes, or branching in the shader code.
    ///
    /// If you are certain you can always use threadgroups with a multiple of `threadExecutionWidth`
    /// threads, then you may want to use MTLComputePipleineDescriptor and its property
    /// `threadGroupSizeIsMultipleOfThreadExecutionWidth` to configure your pipeline state.
    ///
    /// If your shader is doing some more interesting calculations, and your threads need to share memory in some
    /// meaningful way, then you’ll probably want to do something less generalized to choose your threadgroups.
    func threadgroupSizesForDrawableSize(_ drawableSize: CGSize) -> ThreadgroupSizes
    {
        let waveSize = self.threadExecutionWidth
        let maxThreadsPerGroup = self.maxTotalThreadsPerThreadgroup
        
        let drawableWidth = Int(drawableSize.width)
        let drawableHeight = Int(drawableSize.height)

        if drawableWidth == 0 || drawableHeight == 0 {
            print("drawableSize is zero")
            return .zeros
        }
        
        // Determine the set of possible sizes (not exceeding maxThreadsPerGroup).
        var candidates: [ThreadgroupSizes] = []
        for groupWidth in 1...maxThreadsPerGroup {
            for groupHeight in 1...(maxThreadsPerGroup/groupWidth) {
                // Round up the number of groups to ensure the entire drawable size is covered.
                // <http://stackoverflow.com/a/2745086/23649>
                let groupsPerGrid = MTLSize(width: (drawableWidth + groupWidth - 1) / groupWidth,
                                            height: (drawableHeight + groupHeight - 1) / groupHeight,
                                            depth: 1)
                
                candidates.append(ThreadgroupSizes(
                    threadsPerThreadgroup: MTLSize(width: groupWidth, height: groupHeight, depth: 1),
                    threadgroupsPerGrid: groupsPerGrid))
            }
        }
        
        /// Make a rough approximation for how much compute power will be "wasted" (e.g. when the total number
        /// of threads in a group isn’t an even multiple of `threadExecutionWidth`, or when the total number of
        /// threads being dispatched exceeds the drawable size). Smaller is better.
        func _estimatedUnderutilization(_ s: ThreadgroupSizes) -> Int {
            let excessWidth = s.threadsPerThreadgroup.width * s.threadgroupsPerGrid.width - drawableWidth
            let excessHeight = s.threadsPerThreadgroup.height * s.threadgroupsPerGrid.height - drawableHeight
            
            let totalThreadsPerGroup = s.threadsPerThreadgroup.width * s.threadsPerThreadgroup.height
            let totalGroups = s.threadgroupsPerGrid.width * s.threadgroupsPerGrid.height
            
            let excessArea = excessWidth * drawableHeight + excessHeight * drawableWidth + excessWidth * excessHeight
            let excessThreadsPerGroup = (waveSize - totalThreadsPerGroup % waveSize) % waveSize
            
            return excessArea + excessThreadsPerGroup * totalGroups
        }
        
        // Choose the threadgroup sizes which waste the least amount of execution time/power.
        let result = candidates.min { _estimatedUnderutilization($0) < _estimatedUnderutilization($1) }
        return result ?? .zeros
    }
}


/// Playground helper: produce the value of `expr`, or print the given `message` and exit.
/// If `expr` throws an error, the error is also printed.
public func require<T>(_ expr: @autoclosure () throws -> T?, orDie message: @autoclosure () -> String) -> T
{
    do {
        if let result = try expr() { return result }
        else { print(message()) }
    }
    catch {
        print(message())
        print("error: \(error)")
    }
    PlaygroundPage.current.finishExecution()
}


public extension NSView
{
    func addSubview(_ subview: NSView, at origin: CGPoint)
    {
        addSubview(subview)
        subview.frame.origin = origin
    }
}


public class Label: NSTextField
{
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }
    
    public init(string: String) {
        super.init(frame: .zero)
        isSelectable = false
        isEditable = false
        isBordered = false
        drawsBackground = false
        textColor = .white
        stringValue = string
        sizeToFit()
    }
}
