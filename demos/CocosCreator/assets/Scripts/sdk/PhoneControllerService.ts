import { ControllerInput, ControllerServerState, InputState } from './ControllerInput';

export interface PhoneControllerEnableOptions {
    gameId: string;
    version: number;
    /** Optional prebuilt layout JSON (for editor-generated exported files). */
    layoutData?: any;
}

/**
 * SDK facade that owns ControllerInput lifecycle so game scripts do not need
 * to manually orchestrate launch/connect/cooldown branches.
 */
export class PhoneControllerService {
    private controller: ControllerInput | null = null;

    public onStateChanged: ((state: ControllerServerState, remainingCooldownMs?: number) => void) | null = null;
    public onConnected: (() => void) | null = null;
    public onDisconnected: (() => void) | null = null;
    public onControllerConnected: ((playerId: number) => void) | null = null;
    public onControllerDisconnected: ((playerId: number) => void) | null = null;
    public onPause: (() => void) | null = null;
    public onResume: (() => void) | null = null;
    public onInput: ((playerId: number, state: InputState) => void) | null = null;
    public onError: ((err: any) => void) | null = null;
    public onCooldown: ((remainingMs: number) => void) | null = null;

    public getController(): ControllerInput | null {
        return this.controller;
    }

    public getRemainingCooldownMs(): number {
        return this.controller?.getRemainingCooldownMs() ?? 0;
    }

    public async enable(options: PhoneControllerEnableOptions): Promise<boolean> {
        if (this.controller) {
            const state = this.controller.getState();
            if (state === 'running' || state === 'starting') {
                return true;
            }
        }

        const controller = new ControllerInput();
        this.attachControllerCallbacks(controller);
        this.controller = controller;

        const started = controller.launchServer();
        if (!started) {
            const cooldownMs = controller.getRemainingCooldownMs();
            if (cooldownMs > 0) {
                this.onCooldown?.(cooldownMs);
                this.onStateChanged?.('cooldown', cooldownMs);
            } else {
                this.onStateChanged?.('stopped');
            }
            this.controller = null;
            return false;
        }

        controller.connect(options.gameId, options.version, options.layoutData ?? null);
        return true;
    }

    public disable() {
        if (!this.controller) {
            return;
        }
        this.controller.shutdownServer();
        this.controller = null;
        this.onStateChanged?.('stopped');
    }

    public dispose() {
        this.disable();
    }

    private attachControllerCallbacks(controller: ControllerInput) {
        controller.onStateChanged = (state, remainingCooldownMs) => {
            this.onStateChanged?.(state, remainingCooldownMs);
        };
        controller.onCooldown = (remainingMs) => {
            this.onCooldown?.(remainingMs);
        };
        controller.onConnected = () => this.onConnected?.();
        controller.onDisconnected = () => this.onDisconnected?.();
        controller.onControllerConnected = (playerId) => this.onControllerConnected?.(playerId);
        controller.onControllerDisconnected = (playerId) => this.onControllerDisconnected?.(playerId);
        controller.onPause = () => this.onPause?.();
        controller.onResume = () => this.onResume?.();
        controller.onInput = (playerId, state) => this.onInput?.(playerId, state);
        controller.onError = (err) => this.onError?.(err);
    }
}
