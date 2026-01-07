# Phone Controller SDK - Core

A lightweight .NET library to receive input from your phone controller app via the PC BLE/TCP server.

## Usage

```csharp
using ControllerSdk.Core;

await ControllerInput.Instance.ConnectAsync(); // default: 127.0.0.1:38420

ControllerInput.Instance.OnConnected += () => Debug.Log("Controller connected!");
ControllerInput.Instance.OnDisconnected += () => Debug.Log("Controller disconnected!");

ControllerInput.Instance.OnInputReceived += (state) =>
{
    Debug.Log($"Left Stick: {state.JoyLX:F2}, {state.JoyLY:F2}");
    if ((state.Buttons & (1 << 0)) != 0) Jump(); // Cross button
};

// Or poll:
var input = ControllerInput.Instance.CurrentInput;