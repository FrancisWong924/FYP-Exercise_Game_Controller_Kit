import { _decorator, Component, Button, director, sys, game, Node, Toggle } from 'cc';
import { GameSettings } from './GameSettings';  // Adjust path
const { ccclass, property } = _decorator;

@ccclass('PauseUI')
export class PauseUI extends Component {
    @property(Node)
    mainButtonGroup: Node = null!;

    @property(Node)
    settingsContent: Node = null!;

    @property(Node)
    title: Node = null!;

    @property(Button)
    btnResume: Button = null!;

    @property(Button)
    btnQuit: Button = null!;

    @property(Node)
    alertBox1: Node = null!;

    @property(Node)
    alertBox2: Node = null!;

    @property(Node)
    alertBox3: Node = null!;
    
    private _phoneControllerToggle: Toggle | null = null;
    private _suppressToggleHandler = false;
    private readonly _hideCooldownAlert = () => {
        if (this.alertBox3) this.alertBox3.active = false;
    };

    private readonly onServerConnected = () => {
        if (GameSettings.instance.isPaused) {
            console.log("Auto-resuming: Server Connected");
            if (this.alertBox2) this.alertBox2.active = false;
        }
    };

    private readonly onServerDisconnected = () => {
        if (!GameSettings.instance.isPaused) {
            console.log("Auto-resuming: Server Disconnected");
            this.show();
        }
        if (this.alertBox2) this.alertBox2.active = true;
    };

    private readonly onControllerConnected = () => {
        const c = GameSettings.instance.controller;
        c?.sendCommand(-1, 'ENABLE_STEP');
        c?.sendCommand(-1, 'ENABLE_STEERING');
        if (GameSettings.instance.isPaused) {
            console.log("Auto-resuming: Controller Reconnected");
            if (this.alertBox1) this.alertBox1.active = false;
        }
    };

    private readonly onControllerDisconnected = () => {
        if (!GameSettings.instance.isPaused) {
            console.log("Auto-pausing: Controller Disconnected");
            this.show();
        }
        if (this.alertBox1) this.alertBox1.active = true;
    };

    private readonly onControllerPaused = () => {
        if (!GameSettings.instance.isPaused) {
            this.show();
        }
    };

    private readonly onControllerResumed = () => {
        if (GameSettings.instance.isPaused) {
            this.onResume();
        }
    };

    private readonly onServerCooldown = (remainingMs: number) => {
        const sec = (remainingMs / 1000).toFixed(1);
        console.warn(`[Phone Controller] Restart cooldown active (${sec}s left).`);
        if (this.alertBox3) {
            this.unschedule(this._hideCooldownAlert);
            let p: Node | null = this.alertBox3.parent;
            while (p && p !== this.node) {
                p.active = true;
                p = p.parent;
            }
            this.alertBox3.active = true;
            this.scheduleOnce(this._hideCooldownAlert, 2);
        }
        if (this._phoneControllerToggle) {
            this._suppressToggleHandler = true;
            this._phoneControllerToggle.isChecked = false;
            this._suppressToggleHandler = false;
        }
        GameSettings.instance.enablePhoneController = false;
    };

    onLoad() {
        this.btnResume.node.on('click', this.onResume, this);
        this.btnQuit.node.on('click', this.onQuit, this);

        const gs = GameSettings.instance.node;
        gs.on('SERVER_CONNECTED', this.onServerConnected, this);
        gs.on('SERVER_DISCONNECTED', this.onServerDisconnected, this);
        gs.on('CONTROLLER_CONNECTED', this.onControllerConnected, this);
        gs.on('CONTROLLER_DISCONNECTED', this.onControllerDisconnected, this);
        gs.on('CONTROLLER_PAUSED', this.onControllerPaused, this);
        gs.on('CONTROLLER_RESUMED', this.onControllerResumed, this);
        gs.on('SERVER_COOLDOWN', this.onServerCooldown, this);
    }

    onDestroy() {
        this.unschedule(this._hideCooldownAlert);
        this.btnResume.node.off('click', this.onResume, this);
        this.btnQuit.node.off('click', this.onQuit, this);
        const gs = GameSettings.instance.node;
        gs.off('SERVER_CONNECTED', this.onServerConnected, this);
        gs.off('SERVER_DISCONNECTED', this.onServerDisconnected, this);
        gs.off('CONTROLLER_CONNECTED', this.onControllerConnected, this);
        gs.off('CONTROLLER_DISCONNECTED', this.onControllerDisconnected, this);
        gs.off('CONTROLLER_PAUSED', this.onControllerPaused, this);
        gs.off('CONTROLLER_RESUMED', this.onControllerResumed, this);
        gs.off('SERVER_COOLDOWN', this.onServerCooldown, this);
    }

    show() {
        this.node.active = true;
        director.pause();  // Pause game logic (animations, schedulers, etc.)
        GameSettings.instance.isPaused = true;
        this.mainButtonGroup.setPosition(0, -200, 0);
        this.title.active = true;
        this.settingsContent.active = true;
    }

    hide() {
        this.node.active = false;
        director.resume();
        GameSettings.instance.isPaused = false;
    }

    private onResume() {
        this.hide();
    }

    private onQuit() {
        if (sys.isNative && sys.os === sys.OS.WINDOWS) {
            (window as any).closeExternalExe();
        }

        setTimeout(() => {
            game.end();
        }, 1000);
    }

    public async onTogglePhoneController(toggle: Toggle) {
        if (this._suppressToggleHandler) return;
        this._phoneControllerToggle = toggle;
        const isEnabled = toggle.isChecked;
        console.log('Phone Controller Toggled:', isEnabled);

        const ok = await GameSettings.instance.setPhoneControllerEnabled(isEnabled);
        if (!ok && isEnabled) {
            this._suppressToggleHandler = true;
            toggle.isChecked = false;
            this._suppressToggleHandler = false;
        }
    }
}