import Accelerate
import Foundation

/// stanza 1.15.0 `chuliu_edmonds_one_root`, ported line for line.
enum SpanningTree {

    /// `arcs` is `size × size` float32, row = dependent, column = head, index 0
    /// = ROOT. Returns the head of each word 1..<size.
    static func heads(arcs: [Float], size n: Int) -> [Int] {
        var scores = Matrix(n: n, v: [Double](repeating: 0, count: n * n))
        for i in 0 ..< n {
            var row = i == 0 ? [Float](repeating: 0, count: n) : Array(arcs[i * n ..< (i + 1) * n])
            if i > 0 { row[i] = -.infinity }
            let top = row.max() ?? 0
            var sum: Float = 0
            for x in row { sum += expf(x - top) }
            let lse = logf(sum)
            for j in 0 ..< n { scores[i, j] = Double(row[j] - top - lse) }
        }
        return Array(oneRoot(scores).dropFirst())
    }

    struct Matrix {
        var n: Int
        var v: [Double]
        subscript(_ i: Int, _ j: Int) -> Double {
            get { v[i * n + j] }
            set { v[i * n + j] = newValue }
        }
    }

    private static func oneRoot(_ input: Matrix) -> [Int] {
        var s = input
        let lowest = s.v.filter(\.isFinite).min() ?? 0
        for i in 0 ..< s.n { s[i, 0] += lowest * Double(s.n) }
        return chuliuEdmonds(s)
    }

    private static func chuliuEdmonds(_ input: Matrix) -> [Int] {
        var scores = input
        prepare(&scores)
        var tree = rowArgmax(scores)
        var pending = cycles(in: tree)
        var contractions: [([Int], Contraction)] = []
        while let cycle = pending.popLast() {
            let c = contract(tree, cycle, scores)
            contractions.append((tree, c))
            scores = c.subscores
            prepare(&scores)
            tree = rowArgmax(scores)
            pending = cycles(in: tree)
        }
        while let (old, c) = contractions.popLast() { tree = expand(old, tree, c) }
        return tree
    }

    private static func prepare(_ s: inout Matrix) {
        for i in 0 ..< s.n { s[i, i] = -.infinity }
        for j in 0 ..< s.n { s[0, j] = -.infinity }
        s[0, 0] = 0
    }

    private static func argmaxFirst(_ xs: UnsafeBufferPointer<Double>) -> Int {
        guard let start = xs.baseAddress else { return 0 }
        var top = 0.0, at: vDSP_Length = 0
        vDSP_maxviD(start, 1, &top, &at, vDSP_Length(xs.count))
        return Int(at)
    }

    private static func rowArgmax(_ s: Matrix) -> [Int] {
        s.v.withUnsafeBufferPointer { v in
            (0 ..< s.n).map { i in argmaxFirst(UnsafeBufferPointer(rebasing: v[i * s.n ..< (i + 1) * s.n])) }
        }
    }

    private static func cycles(in tree: [Int]) -> [[Bool]] {
        let count = tree.count
        var indices = [Int](repeating: -1, count: count), lowlinks = indices
        var onStack = [Bool](repeating: false, count: count)
        var stack: [Int] = [], index = 0, found: [[Bool]] = []
        var first = [Int](repeating: 0, count: count + 1)
        for head in tree { first[head + 1] += 1 }
        for i in 0 ..< count { first[i + 1] += first[i] }
        var children = [Int](repeating: 0, count: count), filled = first
        for (dependent, head) in tree.enumerated() {
            children[filled[head]] = dependent
            filled[head] += 1
        }
        func maybePop(_ i: Int) {
            guard lowlinks[i] == indices[i] else { return }
            var cycle = [Bool](repeating: false, count: count)
            var size = 1
            while let top = stack.last, top != i {
                let j = stack.removeLast()
                onStack[j] = false
                cycle[j] = true
                size += 1
            }
            stack.removeLast()
            onStack[i] = false
            cycle[i] = true
            if size > 1 { found.append(cycle) }
        }
        func strongConnect(_ start: Int) {
            var call: [(i: Int, pos: Int, j: Int)] = [(start, -1, -1)]
            while let frame = call.popLast() {
                let i = frame.i
                var pos = frame.pos
                if pos < 0 {
                    indices[i] = index
                    lowlinks[i] = index
                    index += 1
                    stack.append(i)
                    onStack[i] = true
                    pos = first[i]
                } else {
                    lowlinks[i] = min(lowlinks[i], lowlinks[frame.j])
                }
                var descended = false
                while pos < first[i + 1] {
                    let j = children[pos]
                    pos += 1
                    if indices[j] == -1 {
                        call.append((i, pos, j))
                        call.append((j, -1, -1))
                        descended = true
                        break
                    } else if onStack[j] {
                        lowlinks[i] = min(lowlinks[i], indices[j])
                    }
                }
                if !descended { maybePop(i) }
            }
        }
        for i in 0 ..< count where indices[i] == -1 { strongConnect(i) }
        return found
    }

    private struct Contraction {
        let subscores: Matrix
        let cycleLocs: [Int]
        let noncycleLocs: [Int]
        let metaHeads: [Int]
        let metaDeps: [Int]
    }

    private static func contract(_ tree: [Int], _ cycle: [Bool], _ s: Matrix) -> Contraction {
        let n = s.n
        let cl = (0 ..< n).filter { cycle[$0] }
        let nl = (0 ..< n).filter { !cycle[$0] }
        let c = cl.count, k = nl.count, m = k + 1
        let cycleScores = cl.map { s[$0, tree[$0]] }
        let cycleScore = cycleScores.reduce(0, +)
        var metaHeads = [Int](repeating: 0, count: k), metaDeps = [Int](repeating: 0, count: k)
        var sub = Matrix(n: m, v: [Double](repeating: 0, count: m * m))
        s.v.withUnsafeBufferPointer { v in
            sub.v.withUnsafeMutableBufferPointer { out in
                for (a, i) in nl.enumerated() {
                    for (b, j) in nl.enumerated() { out[a * m + b] = v[i * n + j] }
                }
                for (b, node) in nl.enumerated() {
                    var bestHead = 0, headScore = v[cl[0] * n + node] - cycleScores[0] + cycleScore
                    var bestDep = 0, depScore = v[node * n + cl[0]]
                    for a in 1 ..< c {
                        let head = v[cl[a] * n + node] - cycleScores[a] + cycleScore
                        if head > headScore { bestHead = a; headScore = head }
                        let dep = v[node * n + cl[a]]
                        if dep > depScore { bestDep = a; depScore = dep }
                    }
                    metaHeads[b] = bestHead
                    metaDeps[b] = bestDep
                    out[(m - 1) * m + b] = headScore
                    out[b * m + m - 1] = depScore
                }
            }
        }
        return Contraction(subscores: sub, cycleLocs: cl, noncycleLocs: nl, metaHeads: metaHeads, metaDeps: metaDeps)
    }

    private static func expand(_ tree: [Int], _ contracted: [Int], _ c: Contraction) -> [Int] {
        let inner = Array(contracted.dropLast())
        let cycleHead = contracted[inner.count]
        var expanded = [Int](repeating: -1, count: tree.count)
        for k in inner.indices {
            expanded[c.noncycleLocs[k]] = inner[k] < inner.count
                ? c.noncycleLocs[inner[k]] : c.cycleLocs[c.metaDeps[k]]
        }
        for l in c.cycleLocs { expanded[l] = tree[l] }
        expanded[c.cycleLocs[c.metaHeads[cycleHead]]] = c.noncycleLocs[cycleHead]
        return expanded
    }
}
