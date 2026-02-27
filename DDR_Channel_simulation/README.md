# DDR Channel Simulation (MATLAB)

> A MATLAB-based DDR PHY simulation that models dual-edge data transmission through a channel with ISI, noise, and jitter, and evaluates timing margin using eye diagrams and BER vs DQS–DQ skew analysis.

---

# 1. Introduction

## What is DDR?

DDR (Double Data Rate) SDRAM is a high-speed synchronous memory interface where data is transferred on both the rising and falling edges of a clock signal. This effectively doubles the data throughput without doubling the clock frequency.

Data Rate = 2 × Clock Frequency

Modern DDR interfaces (DDR3 / DDR4 / DDR5) operate at multi-gigabit speeds and rely on precise timing alignment between:

- DQ  → Data lines  
- DQS → Data strobe (sampling reference)  
- CK  → Clock  

At these speeds, small timing mismatches can cause bit errors, making signal integrity and timing margin critical.

---

# 2. Why DDR Timing Matters

At high speeds, the following impairments affect signal reliability:

- Inter-Symbol Interference (ISI)
- Additive noise
- Random jitter
- Deterministic jitter
- DQS–DQ skew (sampling misalignment)

To maintain reliability, real DDR controllers perform training procedures such as:

- Read leveling
- Write leveling
- DQS centering
- Per-bit deskew
- Vref calibration

The goal of all these procedures is simple:

> Sample the data at the center of the eye to minimize BER.

This project simulates that concept in a simplified and visual way.

---

# 🧩 3. System Block Diagram

Below is the conceptual flow modeled in this project:

```
        +-------------+
        |   TX (DQ)   |
        | Dual-Edge   |
        +-------------+
               |
               v
        +-------------+
        |   Channel   |
        | ISI + Noise |
        |  + Jitter   |
        +-------------+
               |
               v
        +-------------+
        | RX Sampler  |
        | (DQS edge)  |
        +-------------+
               |
               v
        +-------------+
        |  Decision   |
        |   Logic     |
        +-------------+
               |
               v
              BER
```

---

# 4. What This Project Simulates

This MATLAB project models a simplified DDR physical layer:

### Transmitter (TX)
- Random bit generation
- Dual-edge mapping (DDR-style)
- Oversampled NRZ waveform generation

### Channel
- ISI modeling using a finite impulse response filter
- Additive white Gaussian noise
- Timing jitter injection

### Receiver (RX)
- DQS-based sampling
- Sampling phase (skew) sweep
- Bit slicing using threshold detection
- BER computation for each skew value

### Visualization
- Half-UI eye diagram
- Full-UI eye diagram
- BER vs DQS–DQ skew curve
- Timing margin metrics

---

# 5. Outputs Generated

Running the simulation produces:

1. BER vs DQS–DQ Skew (log scale)
2. Half-UI Eye Diagram (true DDR eye)
3. Full-UI Eye Diagram
4. Metrics including:
   - Eye height
   - Eye width at chosen BER threshold
   - Minimum BER skew point
   - Estimated ISI delay

These outputs emulate simplified DDR PHY validation behavior.

---

#  6. Key Parameters

You can modify the following parameters inside the script:

- UI (bit period)
- OSR (oversampling ratio)
- alpha_ISI (ISI strength)
- SNR_dB (noise level)
- sigma_jit (random jitter)
- aperture (sampling uncertainty)
- DCD (duty cycle distortion)

Adjusting these allows exploration of:

- Eye closure behavior
- Timing margin reduction
- BER sensitivity to skew
- Impact of jitter and noise

---

# 7. How to Run

1. Open MATLAB
2. Run the main script:

```matlab
ddr.m
```

The simulation will automatically generate plots and print timing metrics.

(Optional) Figures can be saved into a `/plots` directory.

---

# 8. Learning Objective

This project demonstrates:

- How eye diagrams represent timing and voltage margin
- How skew affects sampling reliability
- How jitter and noise increase BER
- Why DQS centering is critical in DDR systems
- How training aligns sampling to the center of the eye

It provides a simplified but practical understanding of DDR PHY timing validation concepts.





