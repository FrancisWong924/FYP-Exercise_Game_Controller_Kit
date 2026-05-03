import { _decorator, Component, Quat, Node, game, math, input, Input, EventMouse } from 'cc';
import { GameSettings } from './GameSettings';
import { ControllerInput, InputState } from './sdk/ControllerInput';

const { ccclass, property } = _decorator;

@ccclass('FPSCamera')
export class FPSCamera extends Component {
    @property(Node)
    head: Node = null!;  // Drag the Head node (camera should be child of Head)

    @property
    sensitivity: number = 200;  // Increased for better feel

    @property
    minPitch: number = -80;
    @property
    maxPitch: number = 80;

    @property
    mouseSensitivity: number = 0.1;

    private controller: ControllerInput | null = null;

    private yaw: number = 0;
    private pitch: number = 0;

    private _rightStickX: number = 0;
    private _rightStickY: number = 0;

    private _inputTimeout: number | null = null;

    start() {
        GameSettings.instance.node.on('PHONE_INPUT', (state: InputState) => {
            this._rightStickX = state.JoyRX;
            this._rightStickY = state.JoyRY;

            console.log('[FPSCamera] Right Joy RX:', this._rightStickX.toFixed(2), 
                        'RY:', this._rightStickY.toFixed(2));

            // Reset timeout every time we get input
            if (this._inputTimeout !== null) {
                clearTimeout(this._inputTimeout);
            }
            this._inputTimeout = setTimeout(() => {
                this._rightStickX = 0;
                this._rightStickY = 0;
                console.log('[FPSCamera] Inputs reset to neutral');
            }, 100);
        }, this);
    }

    onLoad() {
        // 1. Listen for mouse movement
        input.on(Input.EventType.MOUSE_MOVE, this.onMouseMove, this);
    }

    onDestroy() {
        if (this._inputTimeout !== null) {
            clearTimeout(this._inputTimeout);
        }

        if (GameSettings.instance && GameSettings.instance.controller) {
            GameSettings.instance.controller.onInput = null;
        }
    }

    onMouseMove(event: EventMouse) {
        // Only update if the mouse is locked (standard for FPS)
        // Horizontal: Mouse X affects Yaw
        const deltaX = event.getDeltaX();
        this.yaw -= deltaX * this.mouseSensitivity;

        // Vertical: Mouse Y affects Pitch
        const deltaY = event.getDeltaY();
        this.pitch += deltaY * this.mouseSensitivity;
        this.pitch = math.clamp(this.pitch, this.minPitch, this.maxPitch);
    }

    lateUpdate() {
        if (GameSettings.instance.isPaused) return;
        if (!this.head) return;

        const dt = game.deltaTime;

        if (Math.abs(this._rightStickX) > 0.1) {
            this.yaw -= this._rightStickX * this.sensitivity * dt;
        }

        // Pitch: right joystick Y (up/down look)
        if (Math.abs(this._rightStickY) > 0.1) {
            this.pitch -= this._rightStickY * this.sensitivity * dt;  // Minus = push up (JoyRY negative) → look up
            this.pitch = math.clamp(this.pitch, this.minPitch, this.maxPitch);
        }

        const playerBody = this.node.parent; // This script is likely on FPSCamera/Head
    
        // Rotate Body Left/Right
        if (playerBody) {
            playerBody.setRotationFromEuler(0, this.yaw, 0);
        }

        // Rotate Head Up/Down
        this.head.setRotationFromEuler(this.pitch, 0, 0);
    }
}