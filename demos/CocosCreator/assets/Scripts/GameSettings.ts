import { _decorator, Component, director, resources, JsonAsset, ImageAsset, error } from 'cc';
import { ControllerInput, InputState, ControllerServerState } from './sdk/ControllerInput';
import { PhoneControllerService } from './sdk/PhoneControllerService';
const { ccclass, property } = _decorator;

@ccclass('GameSettings')
export class GameSettings extends Component {
    private static _instance: GameSettings | null = null;
    private phoneControllerService: PhoneControllerService | null = null;

    private controllerLayout: any = null;

    public get controller(): ControllerInput | null {
        return this.phoneControllerService?.getController() ?? null;
    }

    public static get instance(): GameSettings {
        if (!GameSettings._instance) {
            console.error('GameSettings not initialized!');
        }
        return GameSettings._instance!;
    }

    // Settings
    @property
    public enablePhoneController: boolean = false;  // Toggle for phone app

    // Other future settings (volume, graphics, etc.)
    public masterVolume: number = 1.0;
    public isPaused: boolean = false;  // Shared pause state

    onLoad() {
        if (GameSettings._instance) {
            this.destroy();
            return;
        }

        GameSettings._instance = this;
        director.addPersistRootNode(this.node);  // Make persistent across scenes
        this.initPhoneControllerService();
    }

    onDestroy() {
        this.phoneControllerService?.dispose();
        this.phoneControllerService = null;

        if (GameSettings._instance === this) {
            GameSettings._instance = null;
        }
    }

    public async connectController(): Promise<boolean> {
        if (!this.enablePhoneController || !this.phoneControllerService) {
            return false;
        }
        if (!this.controllerLayout) {
            await this.loadLayoutFromJson();
        }
        return this.phoneControllerService.enable({
            gameId: "simple_game",
            version: 1,
            layoutData: this.controllerLayout
        });
    }

    public shutdownController() {
        this.phoneControllerService?.disable();
    }

    /** Inject editor-exported layout JSON from game code before enabling controller. */
    public setControllerLayout(layoutData: any) {
        this.controllerLayout = layoutData;
    }

    public async setPhoneControllerEnabled(enabled: boolean): Promise<boolean> {
        this.enablePhoneController = enabled;
        if (enabled) {
            return this.connectController();
        }
        this.shutdownController();
        return true;
    }

    private loadLayoutFromJson(): Promise<void> {
        return new Promise((resolve) => {
            const jsonPath = 'Icon/New layout'; // Relative to assets/resources
            
            resources.load(jsonPath, JsonAsset, (err, jsonAsset) => {
                if (err) {
                    error(`Failed to load controller layout: ${err.message}`);
                    resolve();
                    return;
                }
                
                // Pass the actual JSON object to your setter
                this.setControllerLayout(jsonAsset.json);
                resolve();
            });
        });
    }

    private initPhoneControllerService() {
        if (this.phoneControllerService) return;
        const service = new PhoneControllerService();
        this.phoneControllerService = service;

        service.onConnected = () => {
            console.log('[Phone Controller] Connected to PC server!');
            this.node.emit('SERVER_CONNECTED');
        };
        service.onDisconnected = () => {
            console.log('[Phone Controller] Disconnected');
            this.node.emit('SERVER_DISCONNECTED');
        };
        service.onControllerConnected = (playerId: number) => this.node.emit('CONTROLLER_CONNECTED', playerId);
        service.onControllerDisconnected = (playerId: number) => this.node.emit('CONTROLLER_DISCONNECTED', playerId);
        service.onPause = () => this.node.emit('CONTROLLER_PAUSED');
        service.onResume = () => this.node.emit('CONTROLLER_RESUMED');
        service.onInput = (_playerId: number, state: InputState) => this.node.emit('PHONE_INPUT', state);
        service.onError = (err) => console.error('[Phone Controller] Error:', err);
        service.onCooldown = (remainingMs) => this.node.emit('SERVER_COOLDOWN', remainingMs);
        service.onStateChanged = (state: ControllerServerState, remainingMs?: number) => {
            this.node.emit('SERVER_STATE_CHANGED', state, remainingMs ?? 0);
            if (state === 'cooldown') {
                this.enablePhoneController = false;
            }
        };
    }
}