import AVFoundation

func test(renderer: AVSampleBufferVideoRenderer, buffer: CMSampleBuffer) {
    renderer.enqueueSampleBuffer(buffer)
}
