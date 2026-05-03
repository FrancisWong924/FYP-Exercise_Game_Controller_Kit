import { _decorator, Component, input, Input, EventKeyboard, KeyCode, Vec3, CapsuleCharacterController, EventGamepad, Node, Quat, Prefab, instantiate, RigidBody } from 'cc';
import { DefaultButtonMasks, InputState } from './sdk/ControllerInput';  // Adjust path if needed
import { GameSettings } from './GameSettings';
const { ccclass, property } = _decorator;

@ccclass('PlayerController')
export class PlayerController extends Component {
    @property(CapsuleCharacterController)
    charController: CapsuleCharacterController = null!;

    @property(Node)
    camera: Node = null!;  // ← NEW: Drag Main Camera here

    @property(Prefab)
    bulletPrefab: Prefab = null!; // Drag your Bullet Prefab here

    @property(Node)
    muzzle: Node = null!; // Drag the 'Muzzle' empty node here

    @property
    bulletSpeed: number = 20.0;

    private _pressedKeys: Set<KeyCode> = new Set<KeyCode>();
    private _velocity = new Vec3(0, 0, 0);
    private _speed = 5.0;
    private _jumpSpeed = 8.0;
    private _gravity = -20.0;
    private _moveInput = new Vec3();
    // Phone controller left stick (from your SDK)
    private _phoneLeftStick = new Vec3(0, 0, 0);
    private _inputTimeout: number | null = null;

    private _tempForward = new Vec3();  // Reusable temps
    private _tempRight = new Vec3();
    private _tempQuat = new Quat();  // ← NEW

    start() {
        // Assign the input logic here!
        GameSettings.instance.node.on('PHONE_INPUT', (state: InputState) => {
            // Update left stick for movement
            this._phoneLeftStick.x = state.JoyLX ?? 0;
            this._phoneLeftStick.z = state.JoyLY ?? 0;
            const stepping = state.Stepping ?? 0;

            if (stepping !== 0) {
                this._phoneLeftStick.z = stepping;  // Convert phone Y (-1 forward) → pos Y
            }

            // Jump on Cross button (bit 0)
            if ((state.Buttons & DefaultButtonMasks.Cross) !== 0 && this.charController.isGrounded) {
                this._velocity.y = this._jumpSpeed;
                console.log('JUMP with phone Cross button!');
            }

            if ((state.Buttons & DefaultButtonMasks.Circle) !== 0) { 
                this.shoot();
            }

            if (this._inputTimeout !== null) {
                clearTimeout(this._inputTimeout);
            }
            this._inputTimeout = setTimeout(() => {
                this._phoneLeftStick.set(0, 0, 0);
                console.log('[Phone Controller] Reset stick to neutral (timeout)');
            }, 100);
        }, this);
    }

    onLoad() {
        this.charController = this.getComponent(CapsuleCharacterController)!;

        input.on(Input.EventType.KEY_DOWN, this.onKeyDown, this);
        input.on(Input.EventType.KEY_UP, this.onKeyUp, this);
        input.on(Input.EventType.GAMEPAD_INPUT, this.onGamepadInput, this);
        input.on(Input.EventType.MOUSE_DOWN, (event) => {
            if (event.getButton() === 0) { // 0 is Left Click
                this.shoot();
            }
        }, this);
    }

    onDestroy() {
        input.off(Input.EventType.KEY_DOWN, this.onKeyDown, this);
        input.off(Input.EventType.KEY_UP, this.onKeyUp, this);
        input.off(Input.EventType.GAMEPAD_INPUT, this.onGamepadInput, this);

        if (this._inputTimeout !== null) {
            clearTimeout(this._inputTimeout);
        }

        if (GameSettings.instance && GameSettings.instance.controller) {
            GameSettings.instance.controller.onInput = null;
        }
    }

    onKeyDown(event: EventKeyboard) {
        this._pressedKeys.add(event.keyCode);
        if (event.keyCode === KeyCode.SPACE && this.charController.isGrounded) {
            this._velocity.y = this._jumpSpeed;
        }
    }

    onKeyUp(event: EventKeyboard) {
        this._pressedKeys.delete(event.keyCode);
    }

    update(deltaTime: number) {
        if (GameSettings.instance.isPaused) return;
        this._handleMovement();
        this._applyGravity(deltaTime);
        this._moveCharacter(deltaTime);
    }

    private _handleMovement() {
        this._moveInput.set(0, 0, 0);

        // Raw relative input (W/S forward/back, A/D strafe)
        if (this._pressedKeys.has(KeyCode.KEY_W)) this._moveInput.z -= 1;
        if (this._pressedKeys.has(KeyCode.KEY_S)) this._moveInput.z += 1;
        if (this._pressedKeys.has(KeyCode.KEY_A)) this._moveInput.x -= 1;
        if (this._pressedKeys.has(KeyCode.KEY_D)) this._moveInput.x += 1;
        this._moveInput.x += this._phoneLeftStick.x;
        this._moveInput.z += this._phoneLeftStick.z;

        if (this._moveInput.length() > 1) {
            this._moveInput.normalize();
        }

        // ← MAGIC: Camera-relative velocity
        if (this.camera) {
            // Get camera world rotation
            this.camera.getWorldRotation(this._tempQuat);
            // Forward: transform local forward (0,0,-1)
            Vec3.transformQuat(this._tempForward, Vec3.FORWARD, this._tempQuat);
            // Right: transform local right (1,0,0)
            Vec3.transformQuat(this._tempRight, Vec3.RIGHT, this._tempQuat);
            this._tempForward.y = 0;
            this._tempRight.y = 0;
            Vec3.normalize(this._tempForward, this._tempForward);
            Vec3.normalize(this._tempRight, this._tempRight);

            // Velocity = strafe (right vec) + forward (forward vec)
            this._velocity.set(0, this._velocity.y, 0);
            Vec3.scaleAndAdd(this._velocity, this._velocity, this._tempRight, this._moveInput.x * this._speed);
            Vec3.scaleAndAdd(this._velocity, this._velocity, this._tempForward, -this._moveInput.z * this._speed);
        } else {
            // Fallback: world-relative
            this._velocity.x = this._moveInput.x * this._speed;
            this._velocity.z = this._moveInput.z * this._speed;
        }
    }

    private _applyGravity(dt: number) {
        if (!this.charController.isGrounded) {
            this._velocity.y += this._gravity * dt;
        } else if (this._velocity.y < 0) {
            this._velocity.y = 0;
        }
    }

    private _moveCharacter(dt: number) {
        const move = this._velocity.clone().multiplyScalar(dt);
        this.charController.move(move);
    }

    private onGamepadInput(event: EventGamepad) {
        const gamepad = event.gamepad;
        this._moveInput.x = gamepad.leftStick.x;
        this._moveInput.z = -gamepad.leftStick.y;
        if (gamepad.buttonSouth.getValue() === 1 && this.charController.isGrounded) {
            this._velocity.y = this._jumpSpeed;
        }
    }

    private shoot() {
        if (!this.bulletPrefab || !this.muzzle) return;

        // 1. Create a copy of the bullet
        const bullet = instantiate(this.bulletPrefab);

        // 2. Set it to the world (usually the scene root)
        this.node.scene.addChild(bullet);

        // 3. Position the bullet at the muzzle
        bullet.setWorldPosition(this.muzzle.worldPosition);

        // 4. Set the bullet's rotation to match the camera/muzzle direction
        bullet.setWorldRotation(this.muzzle.worldRotation);

        // 5. Get the RigidBody to apply force
        const rb = bullet.getComponent(RigidBody);
        if (rb) {
            // Calculate direction based on where the muzzle is pointing (Forward)
            let shootDir = new Vec3();
            Vec3.transformQuat(shootDir, Vec3.FORWARD, this.muzzle.worldRotation);
            
            // We use negative FORWARD because Cocos 3D forward is -Z
            shootDir.multiplyScalar(this.bulletSpeed);

            // Set the velocity
            rb.setLinearVelocity(shootDir);
        }
    }
}