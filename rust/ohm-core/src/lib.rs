//! # ohm-core — OhmLab's optional Rust simulation core
//!
//! A compact modified-nodal-analysis (MNA) engine for linear circuits
//! (R, C, L, and independent V/I sources) with DC operating-point and AC
//! frequency-sweep analyses. It is the Rust half of OhmLab's pluggable engine
//! façade: the Swift app ships with its native Swift MNA engine by default and
//! can link this crate behind the same `SimulationEngineBackend` interface.
//!
//! The public surface is a small C ABI (see `include/ohm_core.h`). Results are
//! returned as JSON so the Swift side can decode them with `Codable` without a
//! generated binding layer.
//!
//! Layout:
//!   • `value`   — SPICE numeric parsing (suffixes and unit letters)
//!   • `netlist` — parsing into a flat element list plus directives
//!   • `linalg`  — field-generic Gaussian elimination (real and complex)
//!   • `dc`/`ac` — the two analyses
//!   • `json`    — result serialization plus serde-based Circuit IR transport
//!   • `ffi`     — the exported C functions

use std::ffi::{c_char, CStr, CString};
use std::os::raw::c_int;

mod transport;

// ─────────────────────────────────────────────────────────────────────────────
// Scalar field: real DC and complex AC share one Gaussian elimination
// ─────────────────────────────────────────────────────────────────────────────

/// The minimal field operations the solver needs. Implemented for `f64` (DC)
/// and `Cplx` (AC) so both analyses share one elimination routine.
trait Field: Copy + PartialEq {
    fn zero() -> Self;
    fn one() -> Self;
    fn add(self, o: Self) -> Self;
    fn sub(self, o: Self) -> Self;
    fn mul(self, o: Self) -> Self;
    fn div(self, o: Self) -> Self;
    /// Squared magnitude, for partial-pivot selection.
    fn magnitude_sq(self) -> f64;
    fn is_zero(self) -> bool {
        self.magnitude_sq() == 0.0
    }
}

impl Field for f64 {
    fn zero() -> Self {
        0.0
    }
    fn one() -> Self {
        1.0
    }
    fn add(self, o: Self) -> Self {
        self + o
    }
    fn sub(self, o: Self) -> Self {
        self - o
    }
    fn mul(self, o: Self) -> Self {
        self * o
    }
    fn div(self, o: Self) -> Self {
        self / o
    }
    fn magnitude_sq(self) -> f64 {
        self * self
    }
}

/// A complex number, used for AC phasors.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Cplx {
    re: f64,
    im: f64,
}

impl Cplx {
    fn new(re: f64, im: f64) -> Self {
        Cplx { re, im }
    }
    fn from_polar(mag: f64, phase_deg: f64) -> Self {
        let theta = phase_deg.to_radians();
        Cplx::new(mag * theta.cos(), mag * theta.sin())
    }
    fn magnitude(self) -> f64 {
        self.re.hypot(self.im)
    }
    fn phase_deg(self) -> f64 {
        if self.re == 0.0 && self.im == 0.0 {
            0.0
        } else {
            self.im.atan2(self.re).to_degrees()
        }
    }
    fn magnitude_db(self) -> f64 {
        let m = self.magnitude();
        if m <= 0.0 {
            -300.0
        } else {
            20.0 * m.log10()
        }
    }
}

impl Field for Cplx {
    fn zero() -> Self {
        Cplx::new(0.0, 0.0)
    }
    fn one() -> Self {
        Cplx::new(1.0, 0.0)
    }
    fn add(self, o: Self) -> Self {
        Cplx::new(self.re + o.re, self.im + o.im)
    }
    fn sub(self, o: Self) -> Self {
        Cplx::new(self.re - o.re, self.im - o.im)
    }
    fn mul(self, o: Self) -> Self {
        Cplx::new(self.re * o.re - self.im * o.im, self.re * o.im + self.im * o.re)
    }
    fn div(self, o: Self) -> Self {
        let d = o.re * o.re + o.im * o.im;
        Cplx::new(
            (self.re * o.re + self.im * o.im) / d,
            (self.im * o.re - self.re * o.im) / d,
        )
    }
    fn magnitude_sq(self) -> f64 {
        self.re * self.re + self.im * self.im
    }
}

/// Solves `a · x = b` by Gaussian elimination with partial pivoting. `a` is a
/// row-major `n × n` matrix. Returns `None` if the system is singular.
fn solve_linear<T: Field>(mut a: Vec<T>, mut b: Vec<T>, n: usize) -> Option<Vec<T>> {
    if n == 0 {
        return Some(vec![]);
    }
    for col in 0..n {
        // Partial pivot: pick the row with the largest magnitude in this column.
        let mut pivot = col;
        let mut best = a[col * n + col].magnitude_sq();
        for row in (col + 1)..n {
            let m = a[row * n + col].magnitude_sq();
            if m > best {
                best = m;
                pivot = row;
            }
        }
        if best == 0.0 {
            return None;
        }
        if pivot != col {
            for k in 0..n {
                a.swap(col * n + k, pivot * n + k);
            }
            b.swap(col, pivot);
        }
        let diag = a[col * n + col];
        for row in (col + 1)..n {
            let factor = a[row * n + col].div(diag);
            if factor.is_zero() {
                continue;
            }
            for k in col..n {
                let v = a[col * n + k].mul(factor);
                a[row * n + k] = a[row * n + k].sub(v);
            }
            let v = b[col].mul(factor);
            b[row] = b[row].sub(v);
        }
    }
    // Back-substitution.
    let mut x = vec![T::zero(); n];
    for row in (0..n).rev() {
        let mut sum = b[row];
        for k in (row + 1)..n {
            sum = sum.sub(a[row * n + k].mul(x[k]));
        }
        x[row] = sum.div(a[row * n + row]);
    }
    Some(x)
}

// ─────────────────────────────────────────────────────────────────────────────
// SPICE numeric values
// ─────────────────────────────────────────────────────────────────────────────

/// Parses a SPICE numeric literal: optional sign, decimal/scientific mantissa,
/// and an optional scale suffix or trailing unit letter. Returns `None` when no
/// number is present.
fn parse_value(token: &str) -> Option<f64> {
    let t = token.trim();
    if t.is_empty() {
        return None;
    }
    let bytes = t.as_bytes();
    let mut i = 0;
    if matches!(bytes[0], b'+' | b'-') {
        i += 1;
    }
    let mut saw_digit = false;
    let mut saw_dot = false;
    while i < bytes.len() {
        match bytes[i] {
            b'0'..=b'9' => {
                saw_digit = true;
                i += 1;
            }
            b'.' if !saw_dot => {
                saw_dot = true;
                i += 1;
            }
            b'e' | b'E' => {
                // Only treat as an exponent if followed by an optional sign and
                // at least one digit (otherwise it is a unit letter like "E").
                let mut j = i + 1;
                if j < bytes.len() && matches!(bytes[j], b'+' | b'-') {
                    j += 1;
                }
                if j < bytes.len() && bytes[j].is_ascii_digit() {
                    i = j;
                    while i < bytes.len() && bytes[i].is_ascii_digit() {
                        i += 1;
                    }
                }
                break;
            }
            _ => break,
        }
    }
    if !saw_digit {
        return None;
    }
    let mantissa: f64 = t[..i].parse().ok()?;
    let suffix = t[i..].trim();
    Some(mantissa * suffix_multiplier(suffix))
}

/// Maps a SPICE suffix (case-insensitive) to its power-of-ten multiplier.
/// SPICE's `M` is milli, `MEG` is mega; any trailing unit letters are ignored.
fn suffix_multiplier(suffix: &str) -> f64 {
    let s = suffix.to_ascii_uppercase();
    let s = s.trim_end_matches(|c: char| c.is_ascii_alphabetic() && !"TPGMKUNF".contains(c));
    // Longest-prefix match, since MEG must win over M.
    let table: [(&str, f64); 10] = [
        ("MEG", 1e6),
        ("MIL", 25.4e-6),
        ("T", 1e12),
        ("G", 1e9),
        ("K", 1e3),
        ("M", 1e-3),
        ("U", 1e-6),
        ("N", 1e-9),
        ("P", 1e-12),
        ("F", 1e-15),
    ];
    for (prefix, mult) in table {
        if s.starts_with(prefix) {
            return mult;
        }
    }
    1.0
}

// ─────────────────────────────────────────────────────────────────────────────
// Netlist model
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Clone, Debug)]
enum Element {
    Resistor { name: String, a: String, b: String, value: f64 },
    Capacitor { name: String, a: String, b: String, value: f64 },
    Inductor { name: String, a: String, b: String, value: f64 },
    VoltageSource { name: String, a: String, b: String, dc: f64, ac: Cplx },
    CurrentSource { name: String, a: String, b: String, dc: f64, ac: Cplx },
}

impl Element {
    fn name(&self) -> &str {
        match self {
            Element::Resistor { name, .. }
            | Element::Capacitor { name, .. }
            | Element::Inductor { name, .. }
            | Element::VoltageSource { name, .. }
            | Element::CurrentSource { name, .. } => name,
        }
    }
    fn nodes(&self) -> (&str, &str) {
        match self {
            Element::Resistor { a, b, .. }
            | Element::Capacitor { a, b, .. }
            | Element::Inductor { a, b, .. }
            | Element::VoltageSource { a, b, .. }
            | Element::CurrentSource { a, b, .. } => (a, b),
        }
    }
    fn is_vsource(&self) -> bool {
        matches!(self, Element::VoltageSource { .. })
    }
    /// Elements that get a branch-current unknown in DC (V and L).
    fn has_branch(&self) -> bool {
        matches!(self, Element::VoltageSource { .. } | Element::Inductor { .. })
    }
}

#[derive(Clone, Debug, PartialEq)]
enum SweepType {
    Decade,
    Octave,
    Linear,
}

#[derive(Clone, Debug)]
struct AcDirective {
    sweep: SweepType,
    points: usize,
    start: f64,
    stop: f64,
}

#[derive(Clone, Debug)]
struct Circuit {
    elements: Vec<Element>,
    ac: Option<AcDirective>,
    warnings: Vec<String>,
    /// Explicit Circuit IR order, including reference node. Netlist input keeps
    /// deriving its order from first use for backward compatibility.
    node_order: Option<Vec<String>>,
}

impl Circuit {
    /// The ordered list of non-ground node names (ground is node `"0"`).
    fn node_names(&self) -> Vec<String> {
        if let Some(order) = &self.node_order {
            return order
                .iter()
                .filter(|name| !is_ground(name))
                .cloned()
                .collect();
        }
        let mut names: Vec<String> = Vec::new();
        for e in &self.elements {
            for n in [e.nodes().0, e.nodes().1] {
                if !is_ground(n) && !names.iter().any(|x| x == n) {
                    names.push(n.to_string());
                }
            }
        }
        names
    }
    fn has_ground(&self) -> bool {
        self.elements
            .iter()
            .any(|e| is_ground(e.nodes().0) || is_ground(e.nodes().1))
    }
}

fn is_ground(node: &str) -> bool {
    node == "0" || node.eq_ignore_ascii_case("gnd")
}

/// Parses a netlist body into a circuit. Lines may start with `*`, `;`, or `$`
/// for comments; directive lines start with `.`.
fn parse_netlist(text: &str) -> Result<Circuit, String> {
    let mut elements = Vec::new();
    let mut ac = None;
    let mut warnings = Vec::new();

    for raw in text.lines() {
        let line = strip_comment(raw).trim();
        if line.is_empty() {
            continue;
        }
        if let Some(directive) = line.strip_prefix('.') {
            let tokens: Vec<&str> = directive.split_whitespace().collect();
            if tokens.is_empty() {
                continue;
            }
            match tokens[0].to_ascii_lowercase().as_str() {
                "ac" => ac = parse_ac_directive(&tokens),
                "dc" => warnings.push(
                    "ohm-core: `.dc` sweeps are not supported by the Rust core; DC sweep skipped."
                        .to_string(),
                ),
                _ => {}
            }
            continue;
        }

        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 2 {
            continue;
        }
        let name = tokens[0].to_string();
        let kind = tokens[0].chars().next().unwrap_or('?').to_ascii_uppercase();
        match kind {
            'R' | 'C' | 'L' => {
                if tokens.len() < 4 {
                    warnings.push(format!("ohm-core: {} is missing a value; skipped.", name));
                    continue;
                }
                let value = match parse_value(tokens[3]) {
                    Some(v) => v,
                    None => {
                        warnings.push(format!("ohm-core: {} has an invalid value; skipped.", name));
                        continue;
                    }
                };
                let a = tokens[1].to_string();
                let b = tokens[2].to_string();
                elements.push(match kind {
                    'R' => Element::Resistor { name, a, b, value },
                    'C' => Element::Capacitor { name, a, b, value },
                    _ => Element::Inductor { name, a, b, value },
                });
            }
            'V' | 'I' => {
                let (dc, ac_phasor) = parse_source(&tokens);
                let a = tokens[1].to_string();
                let b = tokens[2].to_string();
                elements.push(if kind == 'V' {
                    Element::VoltageSource { name, a, b, dc, ac: ac_phasor }
                } else {
                    Element::CurrentSource { name, a, b, dc, ac: ac_phasor }
                });
            }
            _ => warnings.push(format!(
                "ohm-core: device \"{}\" is not supported by the Rust core; skipped.",
                name
            )),
        }
    }

    Ok(Circuit {
        elements,
        ac,
        warnings,
        node_order: None,
    })
}

fn strip_comment(line: &str) -> &str {
    for (i, ch) in line.char_indices() {
        if matches!(ch, ';' | '$') {
            return &line[..i];
        }
    }
    if line.trim_start().starts_with('*') {
        return "";
    }
    line
}

fn parse_ac_directive(tokens: &[&str]) -> Option<AcDirective> {
    // `.ac dec <n> <fstart> <fstop>`
    if tokens.len() < 5 {
        return None;
    }
    let sweep = match tokens[1].to_ascii_lowercase().as_str() {
        "dec" => SweepType::Decade,
        "oct" => SweepType::Octave,
        "lin" => SweepType::Linear,
        _ => return None,
    };
    let points: usize = tokens[2].parse().ok()?;
    let start = parse_value(tokens[3])?;
    let stop = parse_value(tokens[4])?;
    Some(AcDirective { sweep, points, start, stop })
}

/// Parses the value portion of a V/I source: `DC <v>` and/or `AC <mag> [phase]`.
fn parse_source(tokens: &[&str]) -> (f64, Cplx) {
    let mut dc = 0.0;
    let mut ac = Cplx::zero();
    let mut i = 3;
    // A bare number in the value slot is taken as the DC level.
    if i < tokens.len() && !is_keyword(tokens[i]) {
        if let Some(v) = parse_value(tokens[i]) {
            dc = v;
        }
        i += 1;
    }
    while i < tokens.len() {
        match tokens[i].to_ascii_lowercase().as_str() {
            "dc" if i + 1 < tokens.len() => {
                dc = parse_value(tokens[i + 1]).unwrap_or(dc);
                i += 2;
            }
            "ac" => {
                let mag = tokens.get(i + 1).and_then(|t| parse_value(t)).unwrap_or(1.0);
                let phase = tokens.get(i + 2).and_then(|t| parse_value(t)).unwrap_or(0.0);
                ac = Cplx::from_polar(mag, phase);
                i += if tokens.get(i + 2).and_then(|t| parse_value(t)).is_some() { 3 } else { 2 };
            }
            _ => i += 1,
        }
    }
    (dc, ac)
}

fn is_keyword(token: &str) -> bool {
    matches!(token.to_ascii_lowercase().as_str(), "dc" | "ac" | "sin" | "pulse" | "pwl")
}

// ─────────────────────────────────────────────────────────────────────────────
// DC analysis
// ─────────────────────────────────────────────────────────────────────────────

struct DcSolution {
    /// Node voltages in the same order as `node_names()`.
    voltages: Vec<f64>,
    /// Per-element current from node a to node b, in `elements` order.
    currents: Vec<f64>,
}

fn solve_dc(circuit: &Circuit) -> Result<DcSolution, String> {
    if !circuit.has_ground() {
        return Err("The circuit has no ground (node 0).".to_string());
    }
    let names = circuit.node_names();
    let index_of = |name: &str| -> Option<usize> { names.iter().position(|n| n == name) };
    let branches = circuit.elements.iter().filter(|e| e.has_branch()).count();
    let n = names.len() + branches;

    let mut a = vec![0.0f64; n * n];
    let mut b = vec![0.0f64; n];
    let mut branch_row = names.len();

    // Maps node name to matrix row; ground is intentionally absent (row skipped).
    let row = |name: &str| -> Option<usize> { index_of(name) };

    for e in &circuit.elements {
        let (an, bn) = e.nodes();
        let ra = row(an);
        let rb = row(bn);
        match e {
            Element::Resistor { value, .. } => {
                let g = if *value != 0.0 { 1.0 / *value } else { 0.0 };
                stamp_conductance(&mut a, n, ra, rb, g);
            }
            Element::Capacitor { .. } => { /* open circuit in DC */ }
            Element::Inductor { .. } => {
                stamp_vsource(&mut a, &mut b, n, ra, rb, branch_row, 0.0);
                branch_row += 1;
            }
            Element::VoltageSource { dc, .. } => {
                stamp_vsource(&mut a, &mut b, n, ra, rb, branch_row, *dc);
                branch_row += 1;
            }
            Element::CurrentSource { dc, .. } => {
                // Current I flows from a to b through the source → injected into b.
                if let Some(r) = ra {
                    b[r] -= *dc;
                }
                if let Some(r) = rb {
                    b[r] += *dc;
                }
            }
        }
    }

    let x = solve_linear(a, b, n)
        .ok_or_else(|| "The DC system is singular (floating node or short circuit).".to_string())?;

    let voltages = x[..names.len()].to_vec();

    // Per-element currents.
    let mut currents = Vec::with_capacity(circuit.elements.len());
    let mut branch_cursor = names.len();
    for e in &circuit.elements {
        let (an, bn) = e.nodes();
        let va = value_at(an, &names, &voltages);
        let vb = value_at(bn, &names, &voltages);
        let current = match e {
            Element::Resistor { value, .. } => {
                if *value != 0.0 { (va - vb) / *value } else { 0.0 }
            }
            Element::Capacitor { .. } => 0.0,
            Element::Inductor { .. } | Element::VoltageSource { .. } => {
                let j = x[branch_cursor];
                branch_cursor += 1;
                j
            }
            Element::CurrentSource { dc, .. } => *dc,
        };
        currents.push(current);
    }

    Ok(DcSolution { voltages, currents })
}

fn value_at(name: &str, names: &[String], voltages: &[f64]) -> f64 {
    if is_ground(name) {
        0.0
    } else {
        names.iter().position(|n| n == name).map(|i| voltages[i]).unwrap_or(0.0)
    }
}

fn stamp_conductance(a: &mut [f64], n: usize, ra: Option<usize>, rb: Option<usize>, g: f64) {
    if let Some(x) = ra {
        a[x * n + x] += g;
    }
    if let Some(y) = rb {
        a[y * n + y] += g;
    }
    if let (Some(x), Some(y)) = (ra, rb) {
        a[x * n + y] -= g;
        a[y * n + x] -= g;
    }
}

fn stamp_vsource(
    a: &mut [f64],
    b: &mut [f64],
    n: usize,
    ra: Option<usize>,
    rb: Option<usize>,
    k: usize,
    value: f64,
) {
    if let Some(x) = ra {
        a[x * n + k] += 1.0;
        a[k * n + x] += 1.0;
    }
    if let Some(y) = rb {
        a[y * n + k] -= 1.0;
        a[k * n + y] -= 1.0;
    }
    b[k] = value;
}

fn ac_frequency_points(d: &AcDirective) -> Vec<f64> {
    if d.points == 0 || d.stop <= 0.0 || d.start <= 0.0 || d.stop < d.start {
        return vec![];
    }
    let mut out = Vec::new();
    match d.sweep {
        SweepType::Linear => {
            let steps = d.points.max(1);
            let denom = steps.saturating_sub(1).max(1) as f64;
            for i in 0..steps {
                out.push(d.start + (d.stop - d.start) * (i as f64) / denom);
            }
        }
        SweepType::Decade => {
            let ratio = (d.stop / d.start).log10();
            let total = ((ratio * d.points as f64).ceil() as usize).max(1);
            for i in 0..=total {
                out.push((d.start * 10f64.powf(i as f64 / d.points as f64)).min(d.stop));
            }
            if out.last().copied() != Some(d.stop) {
                out.push(d.stop);
            }
        }
        SweepType::Octave => {
            let ratio = (d.stop / d.start).log2();
            let total = ((ratio * d.points as f64).ceil() as usize).max(1);
            for i in 0..=total {
                out.push((d.start * 2f64.powf(i as f64 / d.points as f64)).min(d.stop));
            }
            if out.last().copied() != Some(d.stop) {
                out.push(d.stop);
            }
        }
    }
    out.truncate(200_000);
    out
}

// ─────────────────────────────────────────────────────────────────────────────
// AC analysis
// ─────────────────────────────────────────────────────────────────────────────

struct AcSolution {
    frequencies: Vec<f64>,
    /// `[node][frequency]` complex node voltages.
    node_voltages: Vec<Vec<Cplx>>,
    /// `[element][frequency]` complex element currents.
    element_currents: Vec<Vec<Cplx>>,
}

fn solve_ac(circuit: &Circuit, directive: &AcDirective) -> Result<AcSolution, String> {
    if !circuit.has_ground() {
        return Err("The circuit has no ground (node 0).".to_string());
    }
    let names = circuit.node_names();
    let frequencies = ac_frequency_points(directive);
    if frequencies.is_empty() {
        return Err("Invalid `.ac` sweep parameters.".to_string());
    }
    let branches = circuit.elements.iter().filter(|e| e.is_vsource()).count();
    let n = names.len() + branches;
    let index_of = |name: &str| -> Option<usize> { names.iter().position(|x| x == name) };

    let mut node_voltages = vec![vec![Cplx::zero(); frequencies.len()]; names.len()];
    let mut element_currents = vec![vec![Cplx::zero(); frequencies.len()]; circuit.elements.len()];

    for (fi, &freq) in frequencies.iter().enumerate() {
        let omega = 2.0 * std::f64::consts::PI * freq;
        let mut a = vec![Cplx::zero(); n * n];
        let mut b = vec![Cplx::zero(); n];
        let mut branch_row = names.len();

        for e in &circuit.elements {
            let (an, bn) = e.nodes();
            let ra = index_of(an);
            let rb = index_of(bn);
            match e {
                Element::Resistor { value, .. } => {
                    let g = if *value != 0.0 { 1.0 / *value } else { 0.0 };
                    stamp_conductance_c(&mut a, n, ra, rb, Cplx::new(g, 0.0));
                }
                Element::Capacitor { value, .. } => {
                    stamp_conductance_c(&mut a, n, ra, rb, Cplx::new(0.0, omega * *value));
                }
                Element::Inductor { value, .. } => {
                    let y = if omega * *value != 0.0 {
                        Cplx::new(0.0, -1.0 / (omega * *value))
                    } else {
                        Cplx::zero()
                    };
                    stamp_conductance_c(&mut a, n, ra, rb, y);
                }
                Element::VoltageSource { ac, .. } => {
                    stamp_vsource_c(&mut a, &mut b, n, ra, rb, branch_row, *ac);
                    branch_row += 1;
                }
                Element::CurrentSource { ac, .. } => {
                    if let Some(r) = ra {
                        b[r] = b[r].sub(*ac);
                    }
                    if let Some(r) = rb {
                        b[r] = b[r].add(*ac);
                    }
                }
            }
        }

        let x = solve_linear(a, b, n).ok_or_else(|| {
            format!("The AC system is singular at {} Hz.", freq)
        })?;

        for (i, v) in x[..names.len()].iter().enumerate() {
            node_voltages[i][fi] = *v;
        }

        let mut branch_cursor = names.len();
        for (ei, e) in circuit.elements.iter().enumerate() {
            let (an, bn) = e.nodes();
            let va = value_at_c(an, &names, &x);
            let vb = value_at_c(bn, &names, &x);
            let current = match e {
                Element::Resistor { value, .. } => {
                    let g = if *value != 0.0 { 1.0 / *value } else { 0.0 };
                    va.sub(vb).mul(Cplx::new(g, 0.0))
                }
                Element::Capacitor { value, .. } => {
                    va.sub(vb).mul(Cplx::new(0.0, omega * *value))
                }
                Element::Inductor { value, .. } => {
                    let y = if omega * *value != 0.0 {
                        Cplx::new(0.0, -1.0 / (omega * *value))
                    } else {
                        Cplx::zero()
                    };
                    va.sub(vb).mul(y)
                }
                Element::VoltageSource { .. } => {
                    let j = x[branch_cursor];
                    branch_cursor += 1;
                    j
                }
                Element::CurrentSource { ac, .. } => *ac,
            };
            element_currents[ei][fi] = current;
        }
    }

    Ok(AcSolution { frequencies, node_voltages, element_currents })
}

fn value_at_c(name: &str, names: &[String], x: &[Cplx]) -> Cplx {
    if is_ground(name) {
        Cplx::zero()
    } else {
        names.iter().position(|n| n == name).map(|i| x[i]).unwrap_or(Cplx::zero())
    }
}

fn stamp_conductance_c(a: &mut [Cplx], n: usize, ra: Option<usize>, rb: Option<usize>, y: Cplx) {
    if let Some(x) = ra {
        a[x * n + x] = a[x * n + x].add(y);
    }
    if let Some(y2) = rb {
        a[y2 * n + y2] = a[y2 * n + y2].add(y);
    }
    if let (Some(x), Some(y2)) = (ra, rb) {
        a[x * n + y2] = a[x * n + y2].sub(y);
        a[y2 * n + x] = a[y2 * n + x].sub(y);
    }
}

fn stamp_vsource_c(
    a: &mut [Cplx],
    b: &mut [Cplx],
    n: usize,
    ra: Option<usize>,
    rb: Option<usize>,
    k: usize,
    value: Cplx,
) {
    let one = Cplx::one();
    if let Some(x) = ra {
        a[x * n + k] = a[x * n + k].add(one);
        a[k * n + x] = a[k * n + x].add(one);
    }
    if let Some(y) = rb {
        a[y * n + k] = a[y * n + k].sub(one);
        a[k * n + y] = a[k * n + y].sub(one);
    }
    b[k] = value;
}

// ─────────────────────────────────────────────────────────────────────────────
// JSON result serialization
// ─────────────────────────────────────────────────────────────────────────────

fn json_number(x: f64) -> String {
    if x.is_finite() {
        // Rust's Display for f64 is already valid JSON.
        format!("{}", x)
    } else {
        "0".to_string()
    }
}

fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn json_string_array(items: &[String]) -> String {
    let parts: Vec<String> = items.iter().map(|s| json_string(s)).collect();
    format!("[{}]", parts.join(","))
}

fn solve_to_json(circuit: &Circuit) -> (String, Vec<String>) {
    solve_to_json_selected(circuit, true, circuit.ac.is_some(), None)
}

fn solve_to_json_selected(
    circuit: &Circuit,
    run_dc: bool,
    run_ac: bool,
    transport_version: Option<u32>,
) -> (String, Vec<String>) {
    let mut warnings = circuit.warnings.clone();
    let mut errors = Vec::new();
    let strict = transport_version.is_some();

    let names = circuit.node_names();
    let mut dc_json = "null".to_string();
    if run_dc {
        match solve_dc(circuit) {
            Ok(sol) => {
            for v in &sol.voltages {
                if !v.is_finite() {
                    warnings.push("ohm-core: non-finite DC node voltage.".to_string());
                }
            }
            let nodes: Vec<String> = names
                .iter()
                .enumerate()
                .map(|(i, name)| {
                    format!(
                        "{{\"name\":{},\"voltage\":{}}}",
                        json_string(name),
                        json_number(sol.voltages[i])
                    )
                })
                .collect();
            let components: Vec<String> = circuit
                .elements
                .iter()
                .enumerate()
                .map(|(i, e)| {
                    let (an, bn) = e.nodes();
                    let va = value_at(an, &names, &sol.voltages);
                    let vb = value_at(bn, &names, &sol.voltages);
                    format!(
                        "{{\"name\":{},\"voltage\":{},\"current\":{}}}",
                        json_string(e.name()),
                        json_number(va - vb),
                        json_number(sol.currents[i])
                    )
                })
                .collect();
            let sources: Vec<String> = circuit
                .elements
                .iter()
                .enumerate()
                .filter_map(|(i, e)| match e {
                    Element::VoltageSource { name, .. } | Element::CurrentSource { name, .. } => {
                        Some(format!(
                            "{{\"name\":{},\"current\":{}}}",
                            json_string(name),
                            json_number(sol.currents[i])
                        ))
                    }
                    _ => None,
                })
                .collect();
            dc_json = format!(
                "{{\"converged\":true,\"nodes\":[{}],\"components\":[{}],\"sources\":[{}]}}",
                nodes.join(","),
                components.join(","),
                sources.join(",")
            );
            }
            Err(message) => {
                if strict {
                    errors.push(message)
                } else {
                    warnings.push(format!("ohm-core: {message}"))
                }
            }
        }
    }

    let mut ac_json = "null".to_string();
    if run_ac {
        if let Some(directive) = &circuit.ac {
            match solve_ac(circuit, directive) {
                Ok(sol) => {
                let freqs: Vec<String> =
                    sol.frequencies.iter().map(|f| json_number(*f)).collect();
                let nodes: Vec<String> = names
                    .iter()
                    .enumerate()
                    .map(|(i, name)| {
                        let response: Vec<String> = sol.frequencies
                            .iter()
                            .enumerate()
                            .map(|(fi, f)| {
                                let v = sol.node_voltages[i][fi];
                                format!(
                                    "{{\"freqHz\":{},\"magnitudeDb\":{},\"phaseDeg\":{}}}",
                                    json_number(*f),
                                    json_number(v.magnitude_db()),
                                    json_number(v.phase_deg())
                                )
                            })
                            .collect();
                        format!(
                            "{{\"name\":{},\"response\":[{}]}}",
                            json_string(name),
                            response.join(",")
                        )
                    })
                    .collect();
                let components: Vec<String> = circuit
                    .elements
                    .iter()
                    .enumerate()
                    .map(|(i, e)| {
                        let response: Vec<String> = sol.frequencies
                            .iter()
                            .enumerate()
                            .map(|(fi, f)| {
                                let c = sol.element_currents[i][fi];
                                format!(
                                    "{{\"freqHz\":{},\"magnitudeDb\":{},\"phaseDeg\":{}}}",
                                    json_number(*f),
                                    json_number(c.magnitude_db()),
                                    json_number(c.phase_deg())
                                )
                            })
                            .collect();
                        format!(
                            "{{\"name\":{},\"response\":[{}]}}",
                            json_string(e.name()),
                            response.join(",")
                        )
                    })
                    .collect();
                ac_json = format!(
                    "{{\"frequencies\":[{}],\"nodes\":[{}],\"components\":[{}]}}",
                    freqs.join(","),
                    nodes.join(","),
                    components.join(",")
                );
                }
                Err(message) => {
                    if strict {
                        errors.push(message)
                    } else {
                        warnings.push(format!("ohm-core: {message}"))
                    }
                }
            }
        }
    }

    let transport = transport_version
        .map(|version| format!(",\"transportVersion\":{version}"))
        .unwrap_or_default();
    let json = format!(
        "{{\"engine\":{},\"contractVersion\":{}{},\"errors\":{},\"warnings\":{},\"dc\":{},\"ac\":{}}}",
        json_string(ENGINE_ID),
        transport::RESULT_CONTRACT_VERSION,
        transport,
        json_string_array(&errors),
        json_string_array(&warnings),
        dc_json,
        ac_json
    );
    (json, warnings)
}

const ENGINE_ID: &str = concat!("ohm-core ", env!("CARGO_PKG_VERSION"));
static VERSION_C: &[u8] = concat!("ohm-core ", env!("CARGO_PKG_VERSION"), "\0").as_bytes();

// ─────────────────────────────────────────────────────────────────────────────
// C ABI
// ─────────────────────────────────────────────────────────────────────────────

/// Returns a `'\0'`-terminated static version string, e.g. `"ohm-core 0.2.0"`.
///
/// # Safety
/// The returned pointer is static and must not be freed.
#[no_mangle]
pub extern "C" fn ohm_engine_version() -> *const c_char {
    VERSION_C.as_ptr() as *const c_char
}

/// Solves `netlist` (a NUL-terminated UTF-8 string) and, on success, writes a
/// heap-allocated JSON result to `*out_json`.
///
/// Returns `0` on success and a negative error code on bad arguments. Solver
/// failures are reported *inside* the JSON (`"warnings"` plus a `null` analysis
/// section), so a `0` return still requires inspecting the payload. The caller
/// owns `*out_json` and must release it with `ohm_free_string`.
///
/// # Safety
/// `netlist` must be a valid NUL-terminated C string and `out_json` a valid,
/// writable pointer.
#[no_mangle]
pub unsafe extern "C" fn ohm_solve(netlist: *const c_char, out_json: *mut *mut c_char) -> c_int {
    if netlist.is_null() || out_json.is_null() {
        return -1;
    }
    let text = match CStr::from_ptr(netlist).to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };

    let json = match parse_netlist(text) {
        Ok(circuit) => solve_to_json(&circuit).0,
        Err(message) => format!("{{\"engine\":{},\"warnings\":[{}],\"dc\":null,\"ac\":null}}",
            json_string(ENGINE_ID),
            json_string(&message)),
    };

    match CString::new(json) {
        Ok(c) => {
            *out_json = c.into_raw();
            0
        }
        Err(_) => -3,
    }
}

/// Solves a versioned Circuit IR transport request. Unlike `ohm_solve`, this
/// entry point never reparses SPICE and rejects unsupported devices atomically.
///
/// # Safety
/// `request_json` must be a valid NUL-terminated C string and `out_json` a
/// valid, writable pointer. The returned string must be released exactly once
/// with [`ohm_free_string`].
#[no_mangle]
pub unsafe extern "C" fn ohm_solve_circuit_ir(
    request_json: *const c_char,
    out_json: *mut *mut c_char,
) -> c_int {
    if request_json.is_null() || out_json.is_null() {
        return -1;
    }
    let text = match CStr::from_ptr(request_json).to_str() {
        Ok(value) => value,
        Err(_) => return -2,
    };
    let json = match transport::Request::decode(text) {
        Ok(request) => {
            let run_dc = request.run_dc();
            match request.into_circuit() {
                Ok(circuit) => solve_to_json_selected(
                    &circuit,
                    run_dc,
                    circuit.ac.is_some(),
                    Some(transport::TRANSPORT_VERSION),
                ).0,
                Err(error) => transport_error_json(&error),
            }
        }
        Err(error) => transport_error_json(&error),
    };
    match CString::new(json) {
        Ok(value) => {
            *out_json = value.into_raw();
            0
        }
        Err(_) => -3,
    }
}

fn transport_error_json(message: &str) -> String {
    format!(
        "{{\"engine\":{},\"contractVersion\":{},\"transportVersion\":{},\"errors\":[{}],\"warnings\":[],\"dc\":null,\"ac\":null}}",
        json_string(ENGINE_ID),
        transport::RESULT_CONTRACT_VERSION,
        transport::TRANSPORT_VERSION,
        json_string(message),
    )
}

/// Frees a string returned by either solve entry point.
///
/// # Safety
/// `s` must be a pointer returned by either solve entry point (or null) and must
/// not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn ohm_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// In-crate tests (run with `cargo test`)
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn dc_of(netlist: &str) -> DcSolution {
        let circuit = parse_netlist(netlist).expect("parse");
        solve_dc(&circuit).expect("dc solve")
    }

    #[test]
    fn parses_spice_suffixes() {
        assert_eq!(parse_value("1k"), Some(1000.0));
        assert_eq!(parse_value("1MEG"), Some(1e6));
        assert_eq!(parse_value("2.2m"), Some(2.2e-3));
        assert_eq!(parse_value("4.7u"), Some(4.7e-6));
        assert_eq!(parse_value("5"), Some(5.0));
        assert_eq!(parse_value("-2.5V"), Some(-2.5));
        assert_eq!(parse_value("1e3"), Some(1000.0));
        assert_eq!(parse_value("3e-2"), Some(0.03));
    }

    #[test]
    fn voltage_divider_dc() {
        // V1 -> 5 V, divider 1k / 1k: midpoint = 2.5 V, R currents = 2.5 mA.
        let sol = dc_of("V1 1 0 5\nR1 1 2 1k\nR2 2 0 1k\n");
        assert!((sol.voltages[0] - 5.0).abs() < 1e-9, "v(1)");
        assert!((sol.voltages[1] - 2.5).abs() < 1e-9, "v(2)");
        // currents: [V1, R1, R2]
        assert!((sol.currents[1] - 0.0025).abs() < 1e-12, "i(R1)");
        assert!((sol.currents[2] - 0.0025).abs() < 1e-12, "i(R2)");
    }

    #[test]
    fn current_source_pulls_node_negative() {
        let sol = dc_of("I1 1 0 1m\nR1 1 0 1k\n");
        assert!((sol.voltages[0] + 1.0).abs() < 1e-9, "v(1) = {}", sol.voltages[0]);
    }

    #[test]
    fn inductor_is_short_in_dc() {
        let sol = dc_of("V1 1 0 5\nL1 1 2 1m\nR1 2 0 1k\n");
        // The inductor shorts node 2 to node 1, so v(2) = 5 V and i = 5 mA.
        assert!((sol.voltages[1] - 5.0).abs() < 1e-9);
        assert!((sol.currents[2] - 0.005).abs() < 1e-12);
    }

    #[test]
    fn capacitor_is_open_in_dc() {
        let sol = dc_of("V1 1 0 5\nC1 1 2 1u\nR1 2 0 1k\n");
        // With no DC path through C1, node 2 floats to 0 V (through R1 to gnd).
        assert!(sol.voltages[1].abs() < 1e-9);
    }

    #[test]
    fn rc_lowpass_ac_rolls_off() {
        // fc = 1/(2πRC) ≈ 1591.5 Hz for R=1k, C=100n.
        let circuit =
            parse_netlist("V1 1 0 AC 1 0\nR1 1 2 1k\nC1 2 0 100n\n.ac dec 10 10 100k\n")
                .expect("parse");
        let ac = solve_ac(&circuit, circuit.ac.as_ref().unwrap()).expect("ac");
        // Find the magnitude at ~fc; it should be about -3 dB.
        let fc = 1.0 / (2.0 * std::f64::consts::PI * 1000.0 * 100e-9);
        let (fi, _) = ac
            .frequencies
            .iter()
            .enumerate()
            .min_by(|a, b| {
                (a.1 - fc).abs().partial_cmp(&(b.1 - fc).abs()).unwrap()
            })
            .unwrap();
        let mag_db = ac.node_voltages[1][fi].magnitude_db();
        assert!((mag_db + 3.0).abs() < 0.5, "mag at fc = {} dB", mag_db);
    }

    #[test]
    fn solves_matching_the_swift_reference_netlist() {
        // The exact shape the app emits for a divider, checking the wire format.
        let circuit = parse_netlist(
            "* divider\nV1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n.op\n",
        )
        .expect("parse");
        let (json, warnings) = solve_to_json(&circuit);
        assert!(warnings.is_empty(), "warnings: {:?}", warnings);
        assert!(json.contains("\"converged\":true"));
        assert!(json.contains("\"name\":\"2\",\"voltage\":2.5"));
    }

    #[test]
    fn unknown_device_warns() {
        let circuit = parse_netlist("Q1 1 2 3 model\nR1 1 0 1k\n").expect("parse");
        assert!(circuit.warnings.iter().any(|w| w.contains("Q1")));
    }
}
