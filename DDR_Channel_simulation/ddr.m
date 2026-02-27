%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% DDR Link Simulation (TX → Channel → RX)
%
% This script simulates a simplified Double‑Data‑Rate (DDR) interface.
% DDR systems transmit data on BOTH the rising edge and falling edge of the
% strobe/clock, meaning one UI contains TWO half‑UI data symbols.
%
% --------------------------- Simulation Flow -----------------------------
% 1) Random data bits are generated.
% 2) Bits are mapped to DDR format:
%       - Even‑indexed bits  → rising edge (first half‑UI)
%       - Odd‑indexed bits   → falling edge (second half‑UI)
%
% 3) Oversampled analog waveform is created:
%       - Zero‑order hold for each half‑UI symbol
%       - Optional ISI added using a simple RC‑like channel model
%       - Additive white Gaussian noise (AWGN) added
%
% 4) Receiver (RX) samples using DQS:
%       - DQS–DQ skew is swept across the UI
%       - Jitter + aperture uncertainty added to sampling instants
%       - Hard decision slicer recovers bits
%       - BER computed for each skew value
%
% 5) Eye Diagrams:
%       - Half‑UI eye (correct DDR eye: 1 crossing)
%       - Full‑UI eye (shows 2 half‑bits in one UI)
%     Zero‑phase filtering (filtfilt) used ONLY for display to center edges.
%
% ---------------------------- Outputs ------------------------------------
% • BER vs DQS–DQ Skew (log scale)
% • Automatically detected eye center (min BER)
% • Half‑UI Eye Diagram (bold, high‑visibility)
% • Full‑UI Eye Diagram (bold, high‑visibility)
%
% ---------------------------- Parameters ---------------------------------
% You can control:
%   UI, OSR           → data rate and sampling resolution
%   SNR_dB            → noise level
%   alpha_ISI         → channel ISI (edge smoothing)
%   sigma_jit         → random jitter
%   aperture          → sampling aperture uncertainty
%   DCD               → duty‑cycle distortion (0 for symmetric)
%
% ---------------------------- Purpose ------------------------------------
% This simulation demonstrates:
%   • DDR dual‑edge sampling
%   • Timing margin and eye opening
%   • Impact of skew, jitter, noise, and ISI
%   • Relationship between physical waveform and BER
%
% Useful for understanding DDR3/DDR4 read timing, DQS alignment,
% timing margin extraction, and eye visualization.
% Author: Harshitha Umesh
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

clear; close all; clc; rng(10);   

%% ===================== defaults =====================
UI         = 1/500e6;   % Unit Interval: 500 Msps per edge => 1.0 Gbps effective
OSR        = 64;        % samples per UI (even). 32 or 64 recommended

N_bits     = 2e4;       % total bits (even enforced)
Vhigh      = 1.0; Vlow = 0.0;

% Channel & timing (tuned for a clean, visible eye)
alpha_ISI  = 0.92;      % 0.90..0.96; higher -> more ISI / slower edges
SNR_dB     = 26;        % higher -> cleaner eye
sigma_jit  = 0.008*UI;  % RMS random jitter (per half-edge sample)
aperture   = 0.008*UI;  % +/- aperture/2 uniform dither
DCD        = 0.00;      % duty-cycle distortion (0 = symmetric)

% Skew sweep (DQS - DQ)
skew_range = linspace(-0.45*UI, 0.45*UI, 41);

% Plot style (bold & visible)
trace_color  = [0.10 0.35 0.90];   % deep blue
trace_alpha  = 0.30;               % 0..1 transparency for eye traces
mean_color   = [0 0 0];            % black mean trace
mean_width   = 2.2;                % thickness of mean trace
eye_ylim     = [-0.15 1.15];       % y-limits for eyes
%% ======================================================================

% Derived
N_bits   = 2*ceil(N_bits/2);               % force even
assert(mod(OSR,2)==0, 'OSR must be even.');
half_UI  = UI/2; OSR_half = OSR/2;

%% ----------------------------- TX -------------------------------------
% Random data and DDR mapping (even->rising, odd->falling)
data_bits  = randi([0 1], N_bits, 1);
even_bits  = data_bits(1:2:end);
odd_bits   = data_bits(2:2:end);
N_sym      = numel(even_bits);

% Half-UI sequence
ddr_half_seq = zeros(2*N_sym,1);
ddr_half_seq(1:2:end) = even_bits;
ddr_half_seq(2:2:end) = odd_bits;

% Oversampled time grid
Fs     = OSR/UI;
dt     = 1/Fs;
T_sig  = N_sym*UI;
t      = (0:dt:T_sig-dt).';
Ns     = numel(t);

% Zero-order hold each half-UI
dq_ideal = Vlow + (Vhigh - Vlow) * repelem(ddr_half_seq, OSR_half);
dq_ideal = dq_ideal(1:Ns);

% Apply simple RC-like ISI (causal) for the BER path
dq_tx = filter(1-alpha_ISI, [1 -alpha_ISI], dq_ideal);

% Noise scaling for AWGN
signal_power = var(dq_tx);
SNR_lin      = 10^(SNR_dB/10);
noise_sigma  = sqrt(signal_power / SNR_lin);

%% --------------------- DQS sampling instants --------------------------
num_half = 2*N_sym;

% Duty-cycle distortion (optional). If DCD = 0 -> equal halves.
if DCD == 0
    edge_times_nom = (0:num_half-1).' * half_UI;
else
    h1 = half_UI * (1 + DCD);
    h2 = half_UI * (1 - DCD);
    half_durations = repmat([h1; h2], ceil(num_half/2), 1);
    half_durations = half_durations(1:num_half);
    edge_times_nom = [0; cumsum(half_durations(1:end-1))];
end

% Interpolator
interp_samp = @(x, ts) interp1(t, x, ts, 'linear', 'extrap');

%% -------------------- BER vs skew computation -------------------------
BER = zeros(size(skew_range));
for k = 1:numel(skew_range)
    skew = skew_range(k);

    % Timing uncertainty
    jitter = sigma_jit .* randn(size(edge_times_nom));
    dither = aperture .* (rand(size(edge_times_nom)) - 0.5);
    sample_times = edge_times_nom + skew + jitter + dither;

    % Sample + AWGN
    samples = interp_samp(dq_tx, sample_times) + noise_sigma*randn(size(sample_times));

    % Hard decision
    thresh  = (Vhigh + Vlow)/2;
    rx_half = samples > thresh;

    % Rebuild bitstream
    rx_even = rx_half(1:2:end);
    rx_odd  = rx_half(2:2:end);
    rx_bits = zeros(N_bits,1);
    rx_bits(1:2:end) = rx_even;
    rx_bits(2:2:end) = rx_odd;

    % BER
    BER(k) = mean(rx_bits ~= data_bits);
end

%% --------------------------- Plot: BER ---------------------------------
figure('Name','BER vs DQS–DQ Skew','Color','w');
semilogy(skew_range/UI, BER, 'o-','Color',trace_color, 'LineWidth',1.9, ...
         'MarkerFaceColor',trace_color, 'MarkerSize',5); hold on; grid on;
xlabel('Skew / UI'); ylabel('Bit Error Rate (BER)');
title('DDR: BER vs DQS–DQ Skew');
ylim([max(min(BER)/3,1e-6) 1]); xlim([min(skew_range)/UI max(skew_range)/UI]);

% Find & annotate the skew giving minimum BER (effective eye center)
[BERmin, idxMin] = min(BER);
skew_center = skew_range(idxMin);
xline(skew_center/UI, '--', ...
      sprintf('center ≈ %.3f UI', skew_center/UI), ...
      'Color',[0.85 0.2 0.2], 'LineWidth', 1.6);
legend({'BER','estimated center'}, 'Location','southwest');
fprintf('Min BER = %.3e at skew = %.3f UI (%.1f ps)\n', ...
        BERmin, skew_center/UI, skew_center*1e12);
hold off;

%% -------------------- Eyes for display (bold & centered) --------------
% For eye plots, use zero-phase filtering so transitions appear centered.
b = 1 - alpha_ISI; a = [1 -alpha_ISI];
dq_eye = filtfilt(b, a, dq_ideal);           % zero-phase version (display only)
dq_eye = dq_eye + noise_sigma*randn(size(dq_eye));

% Segment into Full-UI and Half-UI windows
samples_per_UI    = OSR;
samples_per_half  = OSR/2;

num_ui_segments   = floor(Ns / samples_per_UI);
eye_full = reshape(dq_eye(1:num_ui_segments*samples_per_UI), ...
                   samples_per_UI, []).';

num_half_segments = floor(Ns / samples_per_half);
eye_half = reshape(dq_eye(1:num_half_segments*samples_per_half), ...
                   samples_per_half, []).';

t_ui  = (0:samples_per_UI-1)   * (UI/samples_per_UI);
t_hui = (0:samples_per_half-1) * (half_UI/samples_per_half);

%% ------------------------ Half-UI Eye (bold) --------------------------
figure('Name','DDR Half-UI Eye','Color','w'); hold on;
step = max(1, round(size(eye_half,1)/250));  % show ~250 traces
sel  = 1:step:size(eye_half,1);
for i = sel
    plot(t_hui*1e12, eye_half(i,:), 'Color', [trace_color trace_alpha], 'LineWidth', 1.2);
end
plot(t_hui*1e12, mean(eye_half,1), 'Color', mean_color, 'LineWidth', mean_width);
grid on; xlabel('Time within half-UI (ps)'); ylabel('Voltage (V)');
title(sprintf('DDR Half-UI Eye — Eff Rate = %.2f Gbps, OSR=%d, SNR=%.1f dB', ...
              (1/UI)/1e9, OSR, SNR_dB));
ylim(eye_ylim); xlim([t_hui(1) t_hui(end)]*1e12);
hold off;

%% -------------------------- Full-UI Eye (bold) ------------------------
figure('Name','DDR Full-UI Eye','Color','w'); hold on;
step = max(1, round(size(eye_full,1)/250));
sel  = 1:step:size(eye_full,1);
for i = sel
    plot(t_ui*1e12, eye_full(i,:), 'Color', [trace_color trace_alpha], 'LineWidth', 1.2);
end
plot(t_ui*1e12, mean(eye_full,1), 'Color', mean_color, 'LineWidth', mean_width);
grid on; xlabel('Time within UI (ps)'); ylabel('Voltage (V)');
title('DDR Full-UI Eye (two half-bits)');
ylim(eye_ylim); xlim([t_ui(1) t_ui(end)]*1e12);
hold off;

%% --- calculations----
%% ======================== METRICS & PROOFS ============================
% This section quantifies the eye and explains the BER valley location.

fprintf('\n==================== METRICS & PROOFS ====================\n');

% ---------------- 1) Eye height at the eye center (half-UI) -------------
% Picking the time index nearest the half-UI midpoint (center of eye).
[~, idx_center] = min(abs(t_hui - half_UI/2));
center_samples  = eye_half(:, idx_center);   % many segments at center time

% assuming some estimate: use lower/upper percentiles to avoid outliers.
low_pct  = 5;    % change to 1 for more conservative estimate
high_pct = 95;
low_level  = prctile(center_samples, low_pct);
high_level = prctile(center_samples, high_pct);
eye_height = high_level - low_level;

fprintf('Eye height (at center, %d–%d%% levels) = %.3f V (low=%.3f, high=%.3f)\n', ...
        low_pct, high_pct, eye_height, low_level, high_level);

% ---------------- 2) Eye width at target BER (from BER curve) -----------
% Choose a BER threshold, find the skew interval that stays below it,
% and compute timing margin in ps.
BER_target = 1e-3;      % <-- set your spec threshold here

% Interpolate BER on a dense skew grid (log-domain interpolation).
skew_dense = linspace(min(skew_range), max(skew_range), 2001);
BER_pos    = max(BER, 1e-12);                  % avoid log(0)
BER_dense  = exp(interp1(skew_range, log(BER_pos), skew_dense, 'pchip', 'extrap'));

% Find the contiguous region around the minimum where BER <= target.
[~, iMin] = min(BER_dense);
mask = BER_dense <= BER_target;
% Grow from the minimum to both sides while condition holds.
iL = iMin; while iL>1             && mask(iL-1), iL = iL-1; end
iR = iMin; while iR<numel(mask)   && mask(iR+1), iR = iR+1; end

if any(mask)
    width_time = skew_dense(iR) - skew_dense(iL);         % in seconds
    width_ui   = width_time / UI;
    fprintf('Eye width at BER<=%.1e = %.3f UI (%.1f ps)\n', ...
            BER_target, width_ui, width_time*1e12);
else
    fprintf('Eye width at BER<=%.1e: NOT MET within sweep range.\n', BER_target);
end

% ---------------- 3) Causal ISI group delay -> center shift -------------
% Here BER path used y[n] = a*y[n-1] + (1-a)*x[n] with a = alpha_ISI (causal).
% Continuous-time equivalent H(z) has frequency response:
%   H(e^{jΩ}) = (1-a) / (1 - a e^{-jΩ}),  ω = 2π f Ts
% Group delay (in samples) at low frequency (ω≈0) ≈ a / (1 - a).
a_isi = alpha_ISI;
gd_samples = a_isi / (1 - a_isi);     % samples of delay (at baseband)
Ts = 1/Fs;                             % sample period (oversample)
gd_time = gd_samples * Ts;             % seconds of delay due to ISI filter

% Convert that delay into UI units and compare with measured min-BER skew.
gd_ui          = gd_time / UI;
skew_center_ui = skew_center / UI;
fprintf('Predicted group delay (causal ISI) ≈ %.3f UI; measured min-BER at %.3f UI\n', ...
        gd_ui, skew_center_ui);

% ---------------- 4) Theoretical AWGN-only BER sanity check -------------
% If you sample at the perfect eye center with ONLY AWGN (no jitter/ISI),
% the threshold detector BER for two equally likely levels is:
%    BER_theory = Q( ΔV / (2*σ) ), where ΔV = Vhigh - Vlow, σ = noise_sigma
% This is a lower bound (your simulation has ISI + jitter), so simulated
% BERmin >= BER_theory (typically).
DeltaV     = Vhigh - Vlow;
BER_awgn   = qfunc( (DeltaV) / (2*noise_sigma) );
fprintf('AWGN-only lower-bound BER (ideal sampler) ≈ %.3e\n', BER_awgn);

% Optional: show the ratio between simulated min BER and the bound
if BERmin > 0
    fprintf('Simulated Min BER / AWGN bound ≈ %.2f x\n', BERmin / max(BER_awgn, eps));
end

fprintf('==========================================================\n\n');
%%
%% ===================== SIMPLE DDR TIMING DIAGRAM (5 BITS) =====================
% This figure illustrates DDR behavior similar to the reference image:
% CK/CK#, Command (READ + NOPs), DQS burst, DQ toggles (first 5 bits only)

% --- Use first 5 bits from the TX bitstream ---
num_bits_demo = 5;
bits_demo = data_bits(1:num_bits_demo);

% --- Timing base (5 bits = 2.5 UI; draw ~6 UI for clarity) ---
UI_demo = UI;
t_demo = linspace(0, 6*UI_demo, 1200);   % smooth lines

% --- CK and CK# ---
CK  = 0.5*(square(2*pi*(1/UI_demo)*t_demo) + 1);
CKn = 1 - CK;

% --- Command waveform (READ at T0, then NOPs) ---
cmd = strings(1,6);
cmd(1) = "READ";
cmd(2:6) = "NOP";

% --- DQS burst: start at T2, run for 5 half-UIs ---
t_dqs_start = 2*UI_demo;
t_dqs_end   = t_dqs_start + num_bits_demo*(UI_demo/2);
DQS = zeros(size(t_demo));
mask_dqs = (t_demo >= t_dqs_start) & (t_demo <= t_dqs_end);
DQS(mask_dqs) = 0.5*(square(2*pi*(1/UI_demo)*t_demo(mask_dqs)) + 1);

% --- DQ toggles: each half-UI follows bits_demo ---
DQ = zeros(size(t_demo));
half_ui = UI_demo/2;
for k = 1:num_bits_demo
    t0 = t_dqs_start + (k-1)*half_ui;
    t1 = t0 + half_ui;
    idx = (t_demo >= t0) & (t_demo < t1);
    DQ(idx) = bits_demo(k);
end

% ===================== Draw the timing diagram =====================
figure('Name','DDR Timing (5-bit example)','Color','w','Position',[100 100 950 530]);

tiledlayout(4,1,'Padding','compact','TileSpacing','compact');

% 1) CK & CK#
nexttile;
plot(t_demo*1e9, CK, 'k','LineWidth',1.3); hold on;
plot(t_demo*1e9, CKn,'--','Color',[0.4 0.4 0.4],'LineWidth',1.0);
ylabel('CK / CK#'); ylim([-0.3 1.3]); grid on;
title('CK / CK#');

% 2) Command row
nexttile; hold on; grid on;
ylabel('CMD'); ylim([-0.3 1.3]);
for k = 1:6
    x0 = (k-1)*UI_demo*1e9;  x1 = k*UI_demo*1e9;
    patch([x0 x1 x1 x0],[0 0 1 1],0.92*[1 1 1],'EdgeColor',[0.75 0.75 0.75]);
    text((x0+x1)/2,0.5,cmd(k),'HorizontalAlignment','center','FontWeight','bold');
end
title('Command: READ then NOPs');

% 3) DQS row
nexttile;
plot(t_demo*1e9, DQS,'b','LineWidth',1.4); grid on;
ylabel('DQS'); ylim([-0.3 1.3]);
title('DQS Burst (aligned to read timing)');

% 4) DQ row (5 bits)
nexttile;
plot(t_demo*1e9, DQ,'Color',[0.10 0.45 0.90],'LineWidth',1.6); grid on;
ylabel('DQ'); ylim([-0.3 1.3]);
title('DQ Data (first 5 bits, half-UI toggles)');
xlabel('Time (ns)');

% Mark UI boundaries
for k = 1:6
    xline(k*UI_demo*1e9,':','Color',[0.8 0.8 0.8]);
end

% Save
if ~exist('plots','dir'), mkdir plots; end
saveas(gcf,'plots/ddr_timing_5bit.png');