# ExerSync Kit
 
The ExerSync Kit is an innovative, hardware-free exergaming middleware ecosystem designed to bridge the gap between real-world physical wellness and digital entertainment. Developed as a decoupled, three-tier software infrastructure, it repurposes a user’s existing Android smartphone into a high-precision, multi-axis exercise controller. By translating mobile sensor telemetry into real-time game inputs over a low-latency network layer, the project completely eliminates the need for expensive, proprietary fitness hardware.

# Core System Architecture

The platform achieves its high-performance tracking through three interconnected, specialized software components:
- **Mobile Controller App (Flutter/Android):** A lightweight application that captures live, high-frequency physical telemetry—specifically tilt angles in radians and mechanical acceleration—directly from the smartphone’s built-in Inertial Measurement Unit (IMU) sensors, streaming the data wirelessly over Bluetooth Low Energy (BLE). It features a customizable user interface where layout configurations can be dynamically altered.
- **Middleware Relay Server (C# & .NET Core):** A standalone middle-tier server that maintains point-to-point, fault-tolerant bidirectional BLE connections with the client. It processes raw, highly variable motion data using advanced Digital Signal Processing (DSP) techniques—including Exponential Moving Averages (EMA) and amplitude masking—to cleanly isolate intentional exercise gestures from erratic "walking noise" and hand jitter.
- **Game Engine SDK / Plugins (C# API):** An abstracted, engine-agnostic toolkit designed for popular runtimes like Unity, Godot, and Cocos Creator. It fully encapsulates complex low-level BLE hardware pairing, multi-threading, and data packet parsing behind clean, asynchronous API calls.

# Note

The actual Plugins and Documentation, Server, and Demo Game are locate at the Release tag of this Github repository.
