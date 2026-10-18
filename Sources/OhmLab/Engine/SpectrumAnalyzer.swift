// SpectrumAnalyzer.swift
// Frequency-domain analysis of a sampled time-domain waveform (FFT).
//
// The transient trace is (usually) uniformly sampled, so a spectrum is just a
// windowed discrete Fourier transform of the samples. A window reduces spectral
// leakage when the record does not contain a whole number of cycles; the
// coherent-gain normalisation keeps a pure tone's magnitude in volts regardless
// of which window is chosen. The transform itself is an iterative radix-2 FFT
// (the record is zero-padded up to the next power of two).

import Foundation

/// A windowing function applied before the transform, trading main-lobe width
/// against sidelobe level.
public enum SpectrumWindow: String, CaseIterable, Sendable, Identifiable {
    case rectangular
    case hann
    case hamming
    case blackman

    public var id: Self { self }

    public var title: String {
        switch self {
        case .rectangular: return "Rectangular"
        case .hann: return "Hann"
        case .hamming: return "Hamming"
        case .blackman: return "Blackman"
        }
    }
}

/// One-sided amplitude spectrum of a sampled signal.
public struct Spectrum: Sendable {
    /// Frequency of each bin, from 0 (DC) up to Nyquist.
    public let frequencies: [Double]
    /// One-sided amplitude (peak) at each bin, in the signal's units.
    public let magnitudes: [Double]
    /// `magnitudes` in decibels, floored at `SpectrumAnalyzer.dbFloor`.
    public let magnitudesDb: [Double]
    /// Phase at each bin, in degrees.
    public let phases: [Double]
    /// Spacing between adjacent bins, in hertz.
    public let binWidth: Double
    /// The window used to produce the spectrum.
    public let window: SpectrumWindow

    /// Frequency of the largest non-DC bin, or nil for an empty spectrum.
    public var peakFrequency: Double? {
        var best: (index: Int, magnitude: Double)?
        for (index, magnitude) in magnitudes.enumerated() where index > 0 {
            if best == nil || magnitude > best!.magnitude {
                best = (index, magnitude)
            }
        }
        return best.map { frequencies[$0.index] }
    }
}

public enum SpectrumAnalyzer {
    /// Floor for the dB conversion, matching the usual −200 dB display clamp.
    public static let dbFloor: Double = -200

    /// Analyses `values` sampled at `times`. Returns nil when there are fewer
    /// than two samples or the record spans no time. Non-uniform samples are
    /// resampled onto a uniform grid by linear interpolation so the FFT is
    /// well-defined.
    public static func analyze(
        times: [Double],
        values: [Double],
        window: SpectrumWindow = .hann,
        removeDC: Bool = true
    ) -> Spectrum? {
        guard times.count == values.count, times.count >= 2 else { return nil }
        guard let (uniformTimes, uniformValues) = resampleUniform(times: times, values: values) else {
            return nil
        }
        let sampleCount = uniformValues.count
        guard sampleCount >= 2 else { return nil }

        let dt = uniformTimes[1] - uniformTimes[0]
        guard dt > 0 else { return nil }

        var prepared = uniformValues
        if removeDC {
            let mean = prepared.reduce(0, +) / Double(prepared.count)
            for index in prepared.indices { prepared[index] -= mean }
        }

        let weights = window.weights(count: sampleCount)
        let windowSum = weights.reduce(0, +)
        guard windowSum > 0 else { return nil }

        // Zero-pad up to the next power of two for the radix-2 FFT.
        let fftSize = nextPowerOfTwo(sampleCount)
        var re = [Double](repeating: 0, count: fftSize)
        var im = [Double](repeating: 0, count: fftSize)
        for index in 0..<sampleCount {
            re[index] = prepared[index] * weights[index]
        }
        fft(&re, &im)

        let binCount = fftSize / 2 + 1
        var frequencies = [Double](repeating: 0, count: binCount)
        var magnitudes = [Double](repeating: 0, count: binCount)
        var magnitudesDb = [Double](repeating: dbFloor, count: binCount)
        var phases = [Double](repeating: 0, count: binCount)
        let scale = 2 / windowSum

        for bin in 0..<binCount {
            frequencies[bin] = Double(bin) / (Double(fftSize) * dt)
            let rawMagnitude = (bin == 0 || bin == fftSize / 2)
                ? hypot(re[bin], im[bin]) / windowSum
                : hypot(re[bin], im[bin]) * scale
            magnitudes[bin] = rawMagnitude
            magnitudesDb[bin] = rawMagnitude > 0
                ? max(dbFloor, 20 * log10(rawMagnitude))
                : dbFloor
            phases[bin] = atan2(im[bin], re[bin]) * 180 / .pi
        }

        return Spectrum(
            frequencies: frequencies,
            magnitudes: magnitudes,
            magnitudesDb: magnitudesDb,
            phases: phases,
            binWidth: 1 / (Double(fftSize) * dt),
            window: window
        )
    }

    // MARK: - Resampling

    /// Resamples onto a uniform grid spanning the same interval. Uniform input
    /// passes through unchanged (up to the grid spacing).
    private static func resampleUniform(
        times: [Double],
        values: [Double]
    ) -> (times: [Double], values: [Double])? {
        let start = times[0]
        let end = times[times.count - 1]
        guard end > start else { return nil }
        let interval = end - start

        var isUniform = true
        let nominal = interval / Double(times.count - 1)
        for index in 1..<times.count {
            let step = times[index] - times[index - 1]
            if abs(step - nominal) > nominal * 1e-6 {
                isUniform = false
                break
            }
        }
        if isUniform { return (times, values) }

        let gridSpacing = nominal
        guard gridSpacing > 0 else { return nil }
        var gridTimes: [Double] = []
        var gridValues: [Double] = []
        var source = 0
        var time = start
        while time <= end + gridSpacing * 1e-9 {
            while source < times.count - 2, times[source + 1] < time { source += 1 }
            let t0 = times[source]
            let t1 = times[source + 1]
            let fraction = t1 > t0 ? (time - t0) / (t1 - t0) : 0
            gridTimes.append(time)
            gridValues.append(values[source] + (values[source + 1] - values[source]) * fraction)
            time += gridSpacing
        }
        return (gridTimes, gridValues)
    }

    // MARK: - FFT

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var size = 1
        while size < value { size <<= 1 }
        return size
    }

    /// In-place iterative radix-2 Cooley-Tukey FFT. `re`/`im` must be the same
    /// power-of-two length.
    private static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        guard n > 1 else { return }

        // Bit-reversal permutation.
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }

        var length = 2
        while length <= n {
            let angle = -2 * Double.pi / Double(length)
            let wRe = cos(angle)
            let wIm = sin(angle)
            var start = 0
            while start < n {
                var curRe = 1.0
                var curIm = 0.0
                for offset in 0..<(length / 2) {
                    let even = start + offset
                    let odd = even + length / 2
                    let oddRe = re[odd] * curRe - im[odd] * curIm
                    let oddIm = re[odd] * curIm + im[odd] * curRe
                    re[odd] = re[even] - oddRe
                    im[odd] = im[even] - oddIm
                    re[even] += oddRe
                    im[even] += oddIm
                    let nextRe = curRe * wRe - curIm * wIm
                    curIm = curRe * wIm + curIm * wRe
                    curRe = nextRe
                }
                start += length
            }
            length <<= 1
        }
    }
}

private extension SpectrumWindow {
    /// Window coefficients for a record of `count` samples.
    func weights(count: Int) -> [Double] {
        guard count > 1 else { return [Double](repeating: 1, count: count) }
        let denominator = Double(count - 1)
        return (0..<count).map { index in
            let n = Double(index)
            switch self {
            case .rectangular:
                return 1
            case .hann:
                return 0.5 - 0.5 * cos(2 * .pi * n / denominator)
            case .hamming:
                return 0.54 - 0.46 * cos(2 * .pi * n / denominator)
            case .blackman:
                return 0.42 - 0.5 * cos(2 * .pi * n / denominator)
                    + 0.08 * cos(4 * .pi * n / denominator)
            }
        }
    }
}
