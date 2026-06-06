import XCTest
@testable import pesterm

final class ResolvedGateTests: XCTestCase {

    func testTrueExactlyOnceSequential() {
        let gate = ResolvedGate()
        XCTAssertTrue(gate.tryResolve())
        for _ in 0..<10 {
            XCTAssertFalse(gate.tryResolve())
        }
    }

    func testTrueExactlyOnceConcurrent() {
        let gate = ResolvedGate()
        let count = 1000
        let trues = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: count) { _ in
            if gate.tryResolve() {
                lock.lock()
                trues.add(true)
                lock.unlock()
            }
        }
        XCTAssertEqual(trues.count, 1, "exactly one caller wins under concurrency")
    }
}
