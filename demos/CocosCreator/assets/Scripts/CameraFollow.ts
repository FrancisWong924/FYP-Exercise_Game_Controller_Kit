import { _decorator, Component, Vec3, Quat, Node, math, game } from 'cc';
import { ControllerInput } from './sdk/ControllerInput';
import { InputState } from './sdk/InputState';

const { ccclass, property } = _decorator;

@ccclass('CameraFollow')
export class CameraFollow extends Component {
    @property(Node)
    player: Node = null!;

    @property
    sensitivity: number = 200;  // Increased for better feel

    @property
    tiltSensitivity: number = 150;  // New: How strong tilt affects yaw

    @property
    minPitch: number = -80;
    @property
    maxPitch: number = 80;

    @property({ type: Vec3 })
    offset: Vec3 = new Vec3(0, 3, 8);

    private controller: ControllerInput | null = null;

    private _yaw = 0;
    private _pitch = -20;

    // Raw inputs
    private _rightStickX = 0;
    private _rightStickY = 0;

    private _cameraInputTimeout: number | null = null;

    private _targetPos = new Vec3();
    private _currentPos = new Vec3();
    private _lerpSpeed = 0.1;

    private _tempQuat = new Quat();

    onDestroy() {
        if (this._cameraInputTimeout !== null) {
            clearTimeout(this._cameraInputTimeout);
        }
        this.controller?.disconnect();
    }

    lateUpdate() {
        if (!this.player) return;

        const dt = game.deltaTime;

        if (Math.abs(this._rightStickX) > 0.1) {
            this._yaw -= this._rightStickX * this.sensitivity * dt;
        }

        // Right joystick Y for pitch (up/down look)
        if (Math.abs(this._rightStickY) > 0.1) {
            this._pitch += this._rightStickY * this.sensitivity * dt;
            this._pitch = math.clamp(this._pitch, this.minPitch, this.maxPitch);
        }

        // ... rest of orbit/follow code unchanged ...
        this.player.getWorldPosition(this._targetPos);

        const yawRad = this._yaw * Math.PI / 180;
        const pitchRad = this._pitch * Math.PI / 180;

        const cosPitch = Math.cos(pitchRad);
        const sinPitch = Math.sin(pitchRad);
        const cosYaw = Math.cos(yawRad);
        const sinYaw = Math.sin(yawRad);

        const hDistance = this.offset.z;
        const height = this.offset.y;

        const x = hDistance * cosPitch * sinYaw;
        const y = height + hDistance * sinPitch;
        const z = hDistance * cosPitch * cosYaw;

        const desiredPos = new Vec3(
            this._targetPos.x + x,
            this._targetPos.y + y,
            this._targetPos.z + z
        );

        this.node.getWorldPosition(this._currentPos);
        Vec3.lerp(this._currentPos, this._currentPos, desiredPos, this._lerpSpeed);
        this.node.setWorldPosition(this._currentPos);

        this.node.lookAt(this._targetPos, Vec3.UP);

        // Player faces camera direction
        const forward = new Vec3();
        this.node.getWorldRotation(this._tempQuat);
        Vec3.transformQuat(forward, Vec3.FORWARD, this._tempQuat);
        forward.y = 0;
        forward.normalize();

        const lookPos = Vec3.add(new Vec3(), this._targetPos, forward.multiplyScalar(10));
        this.player.lookAt(lookPos, Vec3.UP);
    }
}