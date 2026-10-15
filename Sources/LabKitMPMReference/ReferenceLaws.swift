// Closed-form laws and exact solutions of the verification suite (rheology-models.md §3 and §7). Owned by WP-O.
// Every formula here was checked against independent quadrature or ODE integration in the note (t8_out.txt,
// t15_out.txt); the Swift versions are checked again by LabKitMPMReferenceTests.

import Foundation
import LabKitCore

public enum ReferenceLaws {
  /// μ₀, T·m/A.
  public static let vacuumPermeability = 4e-7 * Double.pi

  // MARK: Temperature (V12)

  /// Water viscosity (Cheng 2008), Pa·s, T in °C: 1.790·exp[(−1230 − T)·T/(36100 + 360T)] mPa·s.
  public static func chengWaterViscosity(celsius t: Double) -> Double {
    1.790e-3 * exp((-1230 - t) * t / (36_100 + 360 * t))
  }
  /// Glycerol viscosity (Cheng 2008), Pa·s, T in °C: 12100·exp[(−1233 + T)·T/(9900 + 70T)] mPa·s.
  public static func chengGlycerolViscosity(celsius t: Double) -> Double {
    12.1 * exp((-1233 + t) * t / (9900 + 70 * t))
  }
  /// Glycerol VFT fit to Cheng over 0–100 °C (§3.1): η = exp(−11.657 + 1558.36/(T − 163.20)) Pa·s, T in K.
  public static func glycerolVFT(kelvin t: Double) -> Double { exp(-11.657 + 1558.36 / (t - 163.20)) }
  /// Honey brand II (Saxena 2014): η = A₀·exp(E_a/(RT)), A₀ = 1.1 × 10⁻¹⁴ Pa·s, E_a = 85 kJ/mol.
  public static func honeyViscosity(kelvin t: Double) -> Double {
    1.1e-14 * exp(85_000 / (ContinuumMaterial.gasConstant * t))
  }
  /// Effective Arrhenius activation energy between two temperatures from two viscosities, J/mol.
  public static func effectiveActivationEnergy(eta1: Double, t1: Double, eta2: Double, t2: Double) -> Double {
    ContinuumMaterial.gasConstant * log(eta1 / eta2) / (1 / t1 - 1 / t2)
  }

  // MARK: MR fluid (V12)

  /// Carlson's yield law τ_y(H) = C·271 700·φ^1.5239·tanh(6.33 × 10⁻⁶·H), Pa (no toy clamp).
  public static func carlsonYield(field h: Double, solidsFraction phi: Double = 0.315, carrier c: Double = 1) -> Double {
    c * 271_700 * pow(phi, 1.5239) * tanh(6.33e-6 * h)
  }
  /// Carlson's B–H law B = 1.91·φ^1.133·[1 − exp(−10.97·μ₀H)] + μ₀H, T.
  public static func carlsonFluxDensity(field h: Double, solidsFraction phi: Double = 0.315) -> Double {
    let mu0h = vacuumPermeability * h
    return 1.91 * pow(phi, 1.133) * (1 - exp(-10.97 * mu0h)) + mu0h
  }

  // MARK: V1 hydrostatics

  /// Volume ratio at Lagrangian depth Z under Rheo's volumetric law ½K(J² − 1) = −J·ρ₀gZ: J = −a + √(a² + 1).
  public static func hydrostaticVolumeRatio(depth z: Double, density rho: Double, gravity g: Double, bulk k: Double) -> Double {
    let a = rho * g * z / k
    return -a + (a * a + 1).squareRoot()
  }

  // MARK: V2–V5 shear flows of a Herschel–Bulkley fluid

  /// Herschel–Bulkley flow curve τ = τ_y + k·γ̇ⁿ.
  public static func herschelBulkley(rate: Double, yield ty: Double, consistency k: Double, index n: Double) -> Double {
    ty + k * pow(rate, n)
  }

  /// Walled plane Poiseuille (walls at y = ±H, pressure gradient G_p): u(y) (V3).
  public static func poiseuilleVelocity(y: Double, halfWidth hh: Double, gradient gp: Double, yield ty: Double,
                                        consistency k: Double, index n: Double) -> Double {
    let a = (n + 1) / n
    let pre = n / (n + 1) / (pow(k, 1 / n) * gp)
    return pre * (pow(max(gp * hh - ty, 0), a) - pow(max(gp * abs(y) - ty, 0), a))
  }

  /// Incline film (V5): stoppage depth h_c = τ_y/(ρg sin θ).
  public static func stoppageDepth(yield ty: Double, density rho: Double, gravity g: Double, angle theta: Double) -> Double {
    ty / (rho * g * sin(theta))
  }
  /// Incline film surface speed u_s = (n/(n+1))(S/k)^(1/n)(h − h_c)₊^((n+1)/n), S = ρg sin θ.
  public static func filmSurfaceSpeed(depth h: Double, yield ty: Double, consistency k: Double, index n: Double,
                                      density rho: Double, gravity g: Double, angle theta: Double) -> Double {
    let s = rho * g * sin(theta)
    let hc = ty / s
    return n / (n + 1) * pow(s / k, 1 / n) * pow(max(h - hc, 0), (n + 1) / n)
  }

  /// Wall-free periodic shear ("Kolmogorov", V4): body force b_x = F sin κy, κ = 2π/L, stress τ_xy = (F/κ) cos κy.
  /// The exact velocity (zero mean) for a Herschel–Bulkley fluid, by integrating γ̇(τ(y)) on a fine grid
  /// (Simpson-free trapezoid on `samples` points; 2 × 10⁵ points give ≤ 10⁻⁹ relative error).
  public struct KolmogorovProfile: Sendable {
    public let period: Double
    private let ys: [Double]
    private let us: [Double]
    public init(force f: Double, period l: Double, yield ty: Double, consistency k: Double, index n: Double,
                samples: Int = 200_001) {
      period = l
      let kap = 2 * Double.pi / l, amp = f / kap
      var y = [Double](repeating: 0, count: samples), u = [Double](repeating: 0, count: samples)
      func rate(_ yy: Double) -> Double {
        let tau = amp * cos(kap * yy)
        let x = abs(tau) - ty
        return x > 0 ? (tau < 0 ? -1 : 1) * pow(x / k, 1 / n) : 0
      }
      let dy = l / Double(samples - 1)
      var prev = rate(0)
      for i in 1..<samples {
        y[i] = Double(i) * dy
        let r = rate(y[i])
        u[i] = u[i - 1] + 0.5 * (prev + r) * dy
        prev = r
      }
      var mean = 0.0
      for i in 1..<samples { mean += 0.5 * (u[i] + u[i - 1]) * dy }
      mean /= l
      ys = y
      us = u.map { $0 - mean }
    }
    /// u(y), periodic.
    public func velocity(at y: Double) -> Double {
      var yy = y.truncatingRemainder(dividingBy: period)
      if yy < 0 { yy += period }
      let s = yy / period * Double(ys.count - 1)
      let i = min(Int(s), ys.count - 2)
      let f = s - Double(i)
      return us[i] * (1 - f) + us[i + 1] * f
    }
    /// Largest |u|.
    public var maximumSpeed: Double { us.map { abs($0) }.max() ?? 0 }
  }

  /// Kolmogorov Bingham plug half-width y₀ = asin(τ_y/A)/κ, A = F/κ.
  public static func kolmogorovPlugHalfWidth(force f: Double, period l: Double, yield ty: Double) -> Double {
    let kap = 2 * Double.pi / l
    return asin(min(ty / (f / kap), 1)) / kap
  }

  // MARK: V6–V9 homogeneous laws

  /// Maxwell relaxation: exact Gγ₀e^(−t/λ) and the backward-Euler discrete Gγ₀(1 + Δt/λ)^(−n).
  public static func maxwellRelaxation(time t: Double, initial tau0: Double, relaxationTime lam: Double) -> Double {
    tau0 * exp(-t / lam)
  }
  public static func maxwellRelaxationBackwardEuler(steps n: Int, dt: Double, initial tau0: Double,
                                                    relaxationTime lam: Double) -> Double {
    tau0 * pow(1 + dt / lam, -Double(n))
  }
  /// Maxwell start-up of shear τ_xy(t) = ηγ̇(1 − e^(−t/λ)); upper-convected Maxwell N₁ = 2ηλγ̇².
  public static func maxwellStartup(time t: Double, viscosity eta: Double, rate: Double, relaxationTime lam: Double) -> Double {
    eta * rate * (1 - exp(-t / lam))
  }
  public static func ucmFirstNormalStress(viscosity eta: Double, relaxationTime lam: Double, rate: Double) -> Double {
    2 * eta * lam * rate * rate
  }

  /// Moore structure step response λ(t) = λ_ss + (λ₀ − λ_ss)e^(−(A+B)t), λ_ss = A/(A + B).
  public static func structure(time t: Double, initial l0: Double, build a: Double, breakdown b: Double) -> Double {
    let lss = a / (a + b)
    return lss + (l0 - lss) * exp(-(a + b) * t)
  }
  /// The implicit update's discrete solution λ_n = λ_ss + (λ₀ − λ_ss)(1 + (A + B)Δt)^(−n).
  public static func structureDiscrete(steps n: Int, dt: Double, initial l0: Double, build a: Double, breakdown b: Double) -> Double {
    let lss = a / (a + b)
    return lss + (l0 - lss) * pow(1 + (a + b) * dt, -Double(n))
  }

  /// Steady thixotropic flow curve τ(γ̇) = k₀(1 + β·λ_ss^m)·γ̇ with λ_ss = A₀/(A₀ + B₁γ̇) (V9).
  public static func bifurcationStress(rate: Double, k0: Double, beta: Double, m: Double, a0: Double, b1: Double) -> Double {
    let lss = a0 / (a0 + b1 * rate)
    return k0 * (1 + beta * pow(lss, m)) * rate
  }
  /// The local maximum and minimum of the steady curve (log-spaced scan then golden-section refinement).
  public static func bifurcationExtrema(k0: Double, beta: Double, m: Double, a0: Double, b1: Double)
    -> (maxRate: Double, maxStress: Double, minRate: Double, minStress: Double)?
  {
    func f(_ lg: Double) -> Double { bifurcationStress(rate: pow(10, lg), k0: k0, beta: beta, m: m, a0: a0, b1: b1) }
    let lgs = stride(from: -6.0, through: 4.0, by: 0.001).map { $0 }
    var maxI: Int?, minI: Int?
    for i in 1..<(lgs.count - 1) {
      let a = f(lgs[i - 1]), b = f(lgs[i]), c = f(lgs[i + 1])
      if maxI == nil && b > a && b > c { maxI = i } else if maxI != nil && minI == nil && b < a && b < c { minI = i }
    }
    guard let i1 = maxI, let i2 = minI else { return nil }
    func refine(_ i: Int, maximise: Bool) -> Double {
      var lo = lgs[i - 1], hi = lgs[i + 1]
      for _ in 0..<100 {
        let m1 = lo + (hi - lo) * 0.381966, m2 = hi - (hi - lo) * 0.381966
        let better = maximise ? f(m1) > f(m2) : f(m1) < f(m2)
        if better { hi = m2 } else { lo = m1 }
      }
      return 0.5 * (lo + hi)
    }
    let lmax = refine(i1, maximise: true), lmin = refine(i2, maximise: false)
    return (pow(10, lmax), f(lmax), pow(10, lmin), f(lmin))
  }
  /// Steady rates on the curve where τ(γ̇) = τ (up to three roots, ascending), by scanning and bisection.
  public static func bifurcationRoots(stress tau: Double, k0: Double, beta: Double, m: Double, a0: Double, b1: Double) -> [Double] {
    func g(_ lg: Double) -> Double { bifurcationStress(rate: pow(10, lg), k0: k0, beta: beta, m: m, a0: a0, b1: b1) - tau }
    var roots: [Double] = []
    var lgPrev = -8.0, gPrev = g(lgPrev)
    var lg = -8.0
    while lg < 6 {
      lg += 0.001
      let gv = g(lg)
      if (gPrev < 0) != (gv < 0) {
        var lo = lgPrev, hi = lg
        for _ in 0..<80 { let mid = 0.5 * (lo + hi); if (g(lo) < 0) == (g(mid) < 0) { lo = mid } else { hi = mid } }
        roots.append(pow(10, 0.5 * (lo + hi)))
      }
      lgPrev = lg; gPrev = gv
    }
    return roots
  }

  // MARK: V10 Hele-Shaw

  /// Newtonian Hele-Shaw drag time t_HS = ρb²/(12η).
  public static func heleShawTime(density rho: Double, gap b: Double, viscosity eta: Double) -> Double {
    rho * b * b / (12 * eta)
  }
  /// Power-law gap drag coefficient c in dŪ/dt = −cŪⁿ: c = 2k(2(2n+1)/n)ⁿ/(ρb^(n+1)).
  public static func powerLawDragCoefficient(consistency k: Double, index n: Double, density rho: Double, gap b: Double) -> Double {
    2 * k * pow(2 * (2 * n + 1) / n, n) / (rho * pow(b, n + 1))
  }
  /// Exact power-law decay Ū(t) = (Ū₀^(1−n) − (1 − n)ct)₊^(1/(1−n)) and the finite stop time Ū₀^(1−n)/((1 − n)c).
  public static func powerLawDragSpeed(time t: Double, initial u0: Double, coefficient c: Double, index n: Double) -> Double {
    pow(max(pow(u0, 1 - n) - (1 - n) * c * t, 0), 1 / (1 - n))
  }
  public static func powerLawStopTime(initial u0: Double, coefficient c: Double, index n: Double) -> Double {
    pow(u0, 1 - n) / ((1 - n) * c)
  }

  // MARK: V11 oobleck jamming front

  /// Han et al. 2018 front-speed ratio U_f/U₀ = 1/γ_∞, γ_∞ = γ*·ln((φ₀ − φ_m)/(φ − φ_m)). 6.96 at φ = 0.52.
  public static func jammingFrontRatio(phi: Double, phi0: Double = 0.593, phim: Double = 0.452, strainScale g: Double = 0.197) -> Double {
    1 / (g * log((phi0 - phim) / (phi - phim)))
  }
}
