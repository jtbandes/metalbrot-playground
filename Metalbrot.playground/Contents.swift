import PlaygroundSupport
import Cocoa
import Metal
/*:
 ## Drawing Fractals with Minimal Metal
 
 *[Jacob Bandes-Storch](http://bandes-stor.ch/), Feb 2016*

 *Feb 2021: [Updated for Swift 5 / Xcode 12](https://github.com/jtbandes/metalbrot-playground/pull/6)*  
 *Sep 2017: [Updated for Swift 4 / Xcode 9](https://github.com/jtbandes/Metalbrot.playground/pull/4)*  
 *Nov 2016: [Updated for Swift 3.0.1 / Xcode 8.1](https://github.com/jtbandes/Metalbrot.playground/pull/2)*  
 *Sep 2016: Updated for Swift 3*
 
 This playground provides a small interactive example of how to use Metal to render visualizations of [fractals](https://en.wikipedia.org/wiki/Fractal) (namely, the [Mandelbrot set](https://en.wikipedia.org/wiki/Mandelbrot_set) and [Julia sets](https://en.wikipedia.org/wiki/Julia_set)). This certainly isn’t a comprehensive overview of Metal, but hopefully it’s easy to follow and modify. Enjoy!
 
 - Experiment: Click and drag on the fractal. Watch it change from the Mandelbrot set to a Julia set, and morph as you move the mouse. What happens if you click in a black area of the Mandelbrot set, as opposed to a colored area?
 
 - Note: To see the playground output, enable the playground’s Live View in the editor options, or by pressing ⌥⌘↩. To see the extra functions in `Helpers.swift`, enable the Project Navigator via the toolbar or by pressing ⌘1.

     ![upper left button to open the Navigators](navigation1.png)
     ![upper right button to open the Live View](navigation2.png)
 
 - Note: This demo only covers using Metal for **compute functions**. There are a lot more complicated things you can do with the full rendering pipeline. Some further reading material is linked at the end of the playground.
 */
/*:
 ----
 ### Setup
 
 To use Metal, we first need access to a connected graphics card (***device***). Since this is a small demo, we’ll prefer a low-power (integrated) graphics card.
 
 We’ll also need a ***command queue*** to let us send commands to the device.
 */
let device = require(MTLCopyAllDevices().first{ $0.isLowPower } ?? MTLCreateSystemDefaultDevice(),
                     orDie: "need a Metal device")

let commandQueue = require(device.makeCommandQueue(),
                           orDie: "need a command queue")

/*:
 ----
 ***Shaders*** are small programs which run on the graphics card. You can find the sources for them in `Shaders.metal` in the left-hand Project navigator (⌘1) under **Resources**. Xcode precompiles these `.metal` source files into a ***library*** containing a bitcode representation of the shaders, which can later be translated (more quickly than the original sources) into machine code specific to the device.

 This example uses two shaders, or ***compute kernels***, named `mandelbrotShader` and `juliaShader`.
 */

let library = require(device.makeDefaultLibrary(),
                      orDie: "unable to load shader library")

/*:
- Experiment: Open up `Shaders.metal` and glance through it to understand what the shaders are doing.
*/
let mandelbrotShader = require(library.makeFunction(name: "metalbrot::mandelbrotShader"),
                               orDie: "unable to get mandelbrotShader")

let juliaShader = require(library.makeFunction(name: "metalbrot::juliaShader"),
                          orDie: "unable to get juliaShader")

//: The Julia set shader also needs some extra input, an *(x, y)* point, from the CPU. We can pass this via a shared buffer.
let juliaBuffer = require(device.makeBuffer(length: 2 * MemoryLayout<Float32>.stride),
                          orDie: "need an argument buffer")

/*:
 ----
 Before we can use these shaders, Metal needs to know how to request they be executed on the GPU. This information is precomputed and stored as ***compute pipeline state***, which we can reuse repeatedly.
 
 When executing the program, we’ll also have to decide how to utilize the GPU’s threads (how many groups of threads to use, and the number of threads per group). This will depend on the size of the view we want to draw into.
 */
let mandelbrotPipelineState = require(try device.makeComputePipelineState(function: mandelbrotShader),
                                      orDie: "unable to create compute pipeline state")

let juliaPipelineState = require(try device.makeComputePipelineState(function: juliaShader),
                                 orDie: "unable to create compute pipeline state")

var threadgroupSizes = ThreadgroupSizes.zeros  // To be calculated later

/*:
 ----
 ### Drawing
 
 The fundamental way that Metal content gets onscreen is via CAMetalLayer. The layer has a pool of ***textures*** which hold image data. Our shaders will write into these textures, which can then be displayed on the screen.
 
 We’ll use a custom view class called `MetalView` which is backed by a CAMetalLayer, and automatically resizes its “drawable” (texture) to match the view’s size. (MetalKit provides the MTKView class, but it’s overkill for this demo.)
 */
let outputSize = CGSize(width: 300, height: 250)

let metalView = MetalView(frame: CGRect(origin: .zero, size: outputSize), device: device)
let metalLayer = metalView.metalLayer
/*:
 - Experiment: Look at the MetalView implementation to see how it interacts with the CAMetalLayer.
 
 A helper function called `computeAndDraw` in `Helpers.swift` takes care of encoding the commands which execute the shader, and submitting the buffer of encoded commands to the device. All we need to tell it is which pipeline state to use, which texture to draw into, and set up any necessary parameters to the shader functions.
 */
func drawMandelbrotSet() {
  commandQueue.computeAndDraw(into: metalLayer.nextDrawable(), with: threadgroupSizes) {
    $0.setComputePipelineState(mandelbrotPipelineState)
  }
}

func drawJuliaSet(_ point: CGPoint, presentedHandler: @escaping () -> Void) {
  commandQueue.computeAndDraw(
    into: metalLayer.nextDrawable(),
    with: threadgroupSizes,
    presentedHandler: { _ in presentedHandler() }
  ) {
    $0.setComputePipelineState(juliaPipelineState)

    // Pass the (x,y) coordinates of the clicked point via the buffer we allocated ahead of time.
    $0.setBuffer(juliaBuffer, offset: 0, index: 0)
    let buf = juliaBuffer.contents().bindMemory(to: Float32.self, capacity: 2)
    buf[0] = Float32(point.x)
    buf[1] = Float32(point.y)
  }
}
/*:
 - Experiment:
 Go check out the implementation of `computeAndDraw`! Can you understand how it works?
 
 ----
 ### The easy part
 Now for some user interaction! Our view controller draws fractals when the view is first laid out, and whenever the mouse is dragged (user interaction requires Xcode 7.3).
 */
class Controller: NSViewController, MetalViewDelegate {
  var outstandingDraws = 0

  override func viewDidLayout() {
    metalViewDrawableSizeDidChange(metalView)
  }
  func metalViewDrawableSizeDidChange(_ metalView: MetalView) {
    // This helper function chooses how to assign the GPU’s threads to portions of the texture.
    threadgroupSizes = mandelbrotPipelineState.threadgroupSizesForDrawableSize(metalView.metalLayer.drawableSize)
    drawMandelbrotSet()
  }

  override func mouseDown(with event: NSEvent) {
    drawJuliaSetForEvent(event)
  }
  override func mouseDragged(with event: NSEvent) {
    drawJuliaSetForEvent(event)
  }
  override func mouseUp(with event: NSEvent) {
    drawMandelbrotSet()
  }

  func drawJuliaSetForEvent(_ event: NSEvent) {
    // Keep track of draw commands that are still in progress, so we don't queue up
    // more than one per display refresh. (https://stackoverflow.com/q/66254511/23649)
    if outstandingDraws > 1 {
      return
    }
    outstandingDraws += 1

    var pos = metalView.convertToLayer(metalView.convert(event.locationInWindow, from: nil))
    let scale = metalLayer.contentsScale
    pos.x *= scale
    pos.y *= scale

    drawJuliaSet(pos) {
      self.outstandingDraws -= 1
    }
  }
}

//: Finally, we can put our view onscreen!
let controller = Controller()
controller.view = metalView
metalView.delegate = controller

metalView.addSubview(Label(string: "Click me!"), at: CGPoint(x: 5, y: 5))

PlaygroundPage.current.liveView = metalView

/*:
 ----
 ## What Next?
 
 I hope you’ve enjoyed (and learned something from) this demo. If you haven’t already, I encourage you to poke around in `Helpers.swift` and `Shaders.metal`. Try changing the code and see what happens — *take chances, make mistkaes, get messy!*
 
 If you like reading, there’s lots of reading material about Metal available from Apple, as well as excellent resources from others in the community. Just a few examples:
 * Apple’s own [Metal for Developers](https://developer.apple.com/metal/) documentation and resources.
 * [Metal By Example](http://metalbyexample.com/), a blog and book by Warren Moore.
 * [Blog posts about Metal](http://redqueencoder.com/category/metal/) by The Red Queen Coder (Janie Clayton).
 * [Posts and demos](http://flexmonkey.blogspot.co.uk/?view=magazine) by FlexMonkey (Simon Gladman) on topics including Metal and Core Image.
 
 ### Modify this playground!
 
 This demo barely scratches the surface. Here are a handful of ideas for things to try. (If you come up with something cool, I’d love to [hear about it](https://twitter.com/jtbandes)!)
 
 - Experiment: Tweak the `maxiters` and `escape` parameters in the shader source file. Do the fractals look different? Can you notice any difference in speed? Try modifying the playground to use a discrete graphics card, if your machine has one.
 
 
 - Experiment: Adapt this code to display the same fractals on an iOS device. (Metal isn’t supported in the iOS simulator.) You’ll need to use UIView instead of NSView, but most the Metal-related code can remain the same.
 
 
 - Experiment: Choose another fractal or another coloring scheme, and modify `Shaders.metal` to render it.
 
 
 - Experiment: Add a label which shows the coordinates that were clicked in the complex plane.
     
     Bonus: can you share the code which does this x,y-to-complex conversion between Swift and the shader itself? Try moving things into a full Xcode project and setting up a [bridging header](https://developer.apple.com/library/ios/documentation/Swift/Conceptual/BuildingCocoaApps/MixandMatch.html). You might want to use `#ifdef __cplusplus` and/or `extern "C"`.
 
 
 - Experiment: Try using [MTKView](https://developer.apple.com/library/ios/documentation/MetalKit/Reference/MTKView_ClassReference/) instead of the simple `MetalView` in this playground. Use the MTKView’s delegate or a subclass to render each frame, and modify the pipeline so that your fractals can change over time.
     * Try to make the colors change slowly over time.
     * Try to make the visualization zoom in on an [interesting point](https://en.wikipedia.org/wiki/Mandelbrot_set#Image_gallery_of_a_zoom_sequence).
 
 
 - Experiment: Use `CIImage.init(MTLTexture:options:)` to render the fractals into an image. Save an animated GIF using [CGImageDestination](http://stackoverflow.com/q/14915138/23649), or a movie using [AVAssetWriter](http://stackoverflow.com/q/3741323/23649).
 */
