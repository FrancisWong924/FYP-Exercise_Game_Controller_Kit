import { Color, native, sys } from 'cc';
import { JSB } from 'cc/env';

declare const GetCurrentProcessId: () => number;
declare const launchExternalExe: (cmd: string) => boolean;
declare const closeExternalExe: () => boolean;
declare const isExternalExeAlive: () => boolean;
declare const getGamePid: () => number;

export interface InputState {
    PlayerId: number;
    JoyLX: number;
    JoyLY: number;
    JoyRX: number;
    JoyRY: number;
    Buttons: number;
}

export const DefaultButtonMasks = {
    UP: 1 << 0,
    DOWN: 1 << 1,
    LEFT: 1 << 2,
    RIGHT: 1 << 3,
    START: 1 << 4,
    BACK: 1 << 5,
    LS: 1 << 6,
    RS: 1 << 7,
    LB: 1 << 8,
    RB: 1 << 9,
    LT: 1 << 10,
    RT: 1 << 11,
    A: 1 << 12,
    B: 1 << 13,
    X: 1 << 14,
    Y: 1 << 15,
};

export type ControllerServerState = 'stopped' | 'starting' | 'running' | 'stopping' | 'cooldown';

export interface GeotagImageExportResult {
    success: boolean;
    exportPath: string;
    error: string;
}

export interface ExerSyncKitEnableOptions {
    gameId: string;
    version?: number;
    layoutData?: any;
    onStateChanged?: (state: ControllerServerState, remainingCooldownMs?: number) => void;
    onConnected?: () => void;
    onDisconnected?: () => void;
    onServerUnavailable?: (reason: string) => void;
    onControllerConnected?: (playerId: number) => void;
    onControllerDisconnected?: (playerId: number) => void;
    onPause?: () => void;
    onResume?: () => void;
    onInput?: (playerId: number, state: InputState) => void;
}

export class ExerSyncKit {
    private serverName: string = "ExerSyncKitServer.exe";
    private socket: WebSocket | null = null;
    private buffer: string = '';
    /** BLE stack needs a short cool-down after shutdown before relaunch is stable. Shared across instances. */
    private static readonly minRestartDelayMs = 5000;
    private static cooldownUntilMs = 0;

    public onPause: (() => void) | null = null;
    public onResume: (() => void) | null = null;
    public onConnected: (() => void) | null = null;
    public onDisconnected: (() => void) | null = null;
    public onControllerConnected: ((playerId: number) => void) | null = null;
    public onControllerDisconnected: ((playerId: number) => void) | null = null;
    public onError: ((err: any) => void) | null = null;
    /** Fired when launch is blocked by post-shutdown restart cooldown. */
    public onCooldown: ((remainingMs: number) => void) | null = null;
    /** Fired when server lifecycle state changes. */
    public onStateChanged: ((state: ControllerServerState, remainingCooldownMs?: number) => void) | null = null;
    public onServerUnavailable: ((reason: string) => void) | null = null;
    public onInput: ((playerId: number, state: InputState) => void) | null = null;
    public connectedConrollers: number[] = [];

    /** WebSocket has opened at least once this session. */
    private serverStarted = false;
    /** Native server process was launched successfully (CreateProcess). Used for reconnect policy. */
    private processLaunchOk = false;
    private reconnectTimeout: any = null;
    /** Cancels stacked `connect()` delays so a prior timer cannot call `disconnect()` on a good socket. */
    private pendingConnectTimer: ReturnType<typeof setTimeout> | null = null;
    private connectGeneration = 0;
    private currentUrl: string = '';
    private isManualDisconnect: boolean = false;

    private gameId: string = '';
    private version: number = 1;
    private myPredefinedLayout: any = null;
    private isSendingLargeData: boolean = false;
    private currentTransferId: number = 0;
    private lifecycleState: ControllerServerState = 'stopped';
    private cooldownTimer: ReturnType<typeof setTimeout> | null = null;
    private pendingStepResolve: ((value: number) => void) | null = null;
    private pendingStepRequestId: string | null = null;
    private pendingGeotagResolve: ((value: GeotagImageExportResult) => void) | null = null;
    private pendingGeotagRequestId: string | null = null;
    private boundOnStateChanged: ExerSyncKitEnableOptions['onStateChanged'] | null = null;
    private boundOnConnected: ExerSyncKitEnableOptions['onConnected'] | null = null;
    private boundOnDisconnected: ExerSyncKitEnableOptions['onDisconnected'] | null = null;
    private boundOnServerUnavailable: ExerSyncKitEnableOptions['onServerUnavailable'] | null = null;
    private boundOnControllerConnected: ExerSyncKitEnableOptions['onControllerConnected'] | null = null;
    private boundOnControllerDisconnected: ExerSyncKitEnableOptions['onControllerDisconnected'] | null = null;
    private boundOnPause: ExerSyncKitEnableOptions['onPause'] | null = null;
    private boundOnResume: ExerSyncKitEnableOptions['onResume'] | null = null;
    private boundOnInput: ExerSyncKitEnableOptions['onInput'] | null = null;

    private setState(state: ControllerServerState, remainingCooldownMs?: number) {
        if (this.lifecycleState === state) return;
        this.lifecycleState = state;
        this.onStateChanged?.(state, remainingCooldownMs);
    }

    public getRemainingCooldownMs(): number {
        return Math.max(0, ExerSyncKit.cooldownUntilMs - Date.now());
    }

    public getState(): ControllerServerState {
        return this.lifecycleState;
    }

    public isInCooldown(): boolean {
        return this.getRemainingCooldownMs() > 0;
    }

    private bindOptionsCallbacks(options: ExerSyncKitEnableOptions) {
        this.unbindOptionsCallbacks();
        if (options.onStateChanged) {
            this.boundOnStateChanged = options.onStateChanged;
            this.onStateChanged = this.boundOnStateChanged;
        }
        if (options.onConnected) {
            this.boundOnConnected = options.onConnected;
            this.onConnected = this.boundOnConnected;
        }
        if (options.onDisconnected) {
            this.boundOnDisconnected = options.onDisconnected;
            this.onDisconnected = this.boundOnDisconnected;
        }
        if (options.onServerUnavailable) {
            this.boundOnServerUnavailable = options.onServerUnavailable;
            this.onServerUnavailable = this.boundOnServerUnavailable;
        }
        if (options.onControllerConnected) {
            this.boundOnControllerConnected = options.onControllerConnected;
            this.onControllerConnected = this.boundOnControllerConnected;
        }
        if (options.onControllerDisconnected) {
            this.boundOnControllerDisconnected = options.onControllerDisconnected;
            this.onControllerDisconnected = this.boundOnControllerDisconnected;
        }
        if (options.onPause) {
            this.boundOnPause = options.onPause;
            this.onPause = this.boundOnPause;
        }
        if (options.onResume) {
            this.boundOnResume = options.onResume;
            this.onResume = this.boundOnResume;
        }
        if (options.onInput) {
            this.boundOnInput = options.onInput;
            this.onInput = this.boundOnInput;
        }
    }

    private unbindOptionsCallbacks() {
        if (this.boundOnStateChanged) {
            this.onStateChanged = null;
            this.boundOnStateChanged = null;
        }
        if (this.boundOnConnected) {
            this.onConnected = null;
            this.boundOnConnected = null;
        }
        if (this.boundOnDisconnected) {
            this.onDisconnected = null;
            this.boundOnDisconnected = null;
        }
        if (this.boundOnServerUnavailable) {
            this.onServerUnavailable = null;
            this.boundOnServerUnavailable = null;
        }
        if (this.boundOnControllerConnected) {
            this.onControllerConnected = null;
            this.boundOnControllerConnected = null;
        }
        if (this.boundOnControllerDisconnected) {
            this.onControllerDisconnected = null;
            this.boundOnControllerDisconnected = null;
        }
        if (this.boundOnPause) {
            this.onPause = null;
            this.boundOnPause = null;
        }
        if (this.boundOnResume) {
            this.onResume = null;
            this.boundOnResume = null;
        }
        if (this.boundOnInput) {
            this.onInput = null;
            this.boundOnInput = null;
        }
    }

    public async enableAsync(options: ExerSyncKitEnableOptions): Promise<boolean> {
        if (!options?.gameId) {
            throw new Error('gameId is required to enable the ExerSyncKit.');
        }

        this.bindOptionsCallbacks(options);

        if (this.lifecycleState === 'running' || this.lifecycleState === 'starting') {
            return true;
        }

        const started = this.launchServer();
        if (!started) {
            const cooldownMs = this.getRemainingCooldownMs();
            if (cooldownMs > 0) {
                this.onCooldown?.(cooldownMs);
            }
            this.unbindOptionsCallbacks();
            return false;
        }

        this.connect(options.gameId, options.version ?? 1, options.layoutData ?? null);
        return true;
    }

    private isServerStillRunning(): boolean {
        if (typeof isExternalExeAlive !== 'undefined') {
            try {
                return isExternalExeAlive();
            } catch {
                return this.processLaunchOk;
            }
        }
        return this.processLaunchOk;
    }

    private notifyServerUnavailable(reason: string) {
        if (this.isManualDisconnect) return;
        this.processLaunchOk = false;
        this.serverStarted = false;
        console.warn(`[ExerSyncKit] Server unavailable. ${reason}`);
        this.onServerUnavailable?.(reason);
    }

    private startRestartCooldown() {
        ExerSyncKit.cooldownUntilMs = Date.now() + ExerSyncKit.minRestartDelayMs;
        const remaining = this.getRemainingCooldownMs();
        this.onCooldown?.(remaining);
        this.setState('cooldown', remaining);
        if (this.cooldownTimer) {
            clearTimeout(this.cooldownTimer);
            this.cooldownTimer = null;
        }
        this.cooldownTimer = setTimeout(() => {
            this.cooldownTimer = null;
            if (this.getRemainingCooldownMs() <= 0 && this.lifecycleState === 'cooldown') {
                this.setState('stopped');
            }
        }, remaining + 20);
    }

    public launchServer(): boolean {
        if (this.lifecycleState === 'starting' || this.lifecycleState === 'running') {
            console.log(`[ExerSyncKit] launchServer ignored: server is already ${this.lifecycleState}.`);
            return true;
        }
        if (this.lifecycleState === 'stopping') {
            console.warn('[ExerSyncKit] launchServer ignored: server is currently stopping.');
            return false;
        }
        const cooldownMs = this.getRemainingCooldownMs();
        if (cooldownMs > 0) {
            const sec = (cooldownMs / 1000).toFixed(1);
            console.warn(`[ExerSyncKit] Launch blocked by cool-down (${sec}s left).`);
            this.onCooldown?.(cooldownMs);
            this.setState('cooldown', cooldownMs);
            this.processLaunchOk = false;
            return false;
        }
        this.setState('starting');
        if (sys.isNative && sys.os === sys.OS.WINDOWS) {
            try {
                // const rootPath = native.fileUtils.getDefaultResourceRootPath();
                // const fullPath = (rootPath + this.serverName).replace(/\//g, "\\");
                
                const gamePid = typeof getGamePid !== 'undefined' ? getGamePid() : 0;
                const commandLine = `"${this.serverName}" ${gamePid} --no-activate`;

                console.log("[ExerSyncKit] Attempting to launch server:", commandLine);

                // Trigger the C++ bridge
                if (typeof launchExternalExe !== 'undefined') {
                    const didStart = launchExternalExe(commandLine);

                    if (didStart) {
                        console.log("[ExerSyncKit] Server process launched and still running.");
                        this.processLaunchOk = true;
                        this.setState('running');
                    } else {
                        console.error("[ExerSyncKit] Server did not stay running. Check if ExerSyncKitServer.exe exists in your build output folder.");
                        this.processLaunchOk = false;
                        this.setState('stopped');
                    }
                    return didStart;
                } else {
                    console.error("[ExerSyncKit] launchExternalExe not found! Is the C++ bridge linked?");
                    this.setState('stopped');
                    return false;
                }
            } catch (e) {
                console.error("[ExerSyncKit] Failed to launch server:", e);
                this.setState('stopped');
                return false;
            }
        } else {
            console.warn("[ExerSyncKit] launchServer ignored: Not running on Native Windows.");
            this.processLaunchOk = false;
            this.setState('stopped');
            return false;
        }
    }

    public connect(
        gameId: string, 
        version: number = 1, 
        layout: any = null,
        url: string = 'ws://127.0.0.1:38421/controller'
    ) {
        this.gameId = gameId;
        this.version = version;
        this.myPredefinedLayout = layout;
        this.currentUrl = url;
        this.isManualDisconnect = false;
        console.log('custom layout:', this.myPredefinedLayout);
        const cooldownMs = this.getRemainingCooldownMs();
        if (cooldownMs > 0) {
            const sec = (cooldownMs / 1000).toFixed(1);
            console.warn(`[ExerSyncKit] connect() blocked by cooldown (${sec}s left).`);
            this.onCooldown?.(cooldownMs);
            this.setState('cooldown', cooldownMs);
            return;
        }
        // Clear any pending reconnects
        if (this.reconnectTimeout) {
            clearTimeout(this.reconnectTimeout);
            this.reconnectTimeout = null;
        }
        if (this.pendingConnectTimer) {
            clearTimeout(this.pendingConnectTimer);
            this.pendingConnectTimer = null;
        }
        this.connectGeneration++;
        const generation = this.connectGeneration;
        // Server may not bind the socket immediately after CreateProcess; small delay reduces first-connect failures.
        const delayMs = this.processLaunchOk ? 500 : 0;
        if (delayMs > 0) {
            this.pendingConnectTimer = setTimeout(() => {
                this.pendingConnectTimer = null;
                if (generation !== this.connectGeneration) return;
                this.establishConnection();
            }, delayMs);
        } else {
            this.establishConnection();
        }
    }

    private establishConnection() {
        this.disconnect();
        console.log(`[ExerSyncKit] Attempting connection to ${this.currentUrl}...`);

        try {
            // Avoid passing an empty subprotocol list; some native WebSocket stacks behave badly with `[]`.
            this.socket = new WebSocket(this.currentUrl);
            this.socket.binaryType = "arraybuffer";

            this.socket.onopen = () => {
                console.log('[ExerSyncKit] Connected to controller server (WebSocket)');
                this.serverStarted = true;
                this.setState('running');
                this.onConnected?.();
            };

            this.socket.onclose = (event) => {
                console.log('[ExerSyncKit] Disconnected from server');
                console.log('   Code:', event.code);
                console.log('   Reason:', event.reason || '(no reason)');
                console.log('   Was clean:', event.wasClean);
                this.abortOngoingTransfer();
                this.socket = null;
                this.connectedConrollers = [];
                if (this.lifecycleState !== 'cooldown' && this.lifecycleState !== 'stopping') {
                    this.setState('stopped');
                }

                if (!this.isManualDisconnect) {
                    this.onDisconnected?.();
                    if (this.isServerStillRunning()) {
                        this.scheduleReconnect();
                    } else {
                        this.notifyServerUnavailable('Server process is not running.');
                    }
                }
            };

            this.socket.onerror = (err) => {
                console.error('[ExerSyncKit] WebSocket error:', err);
                this.onError?.(err);
            };

            this.socket.onmessage = (event) => {
                let text = "";

                if (typeof event.data === 'string') {
                    text = event.data;
                } else if (event.data instanceof ArrayBuffer) {
                    // Native Cocos usually returns ArrayBuffer for binary
                    text = new TextDecoder("utf-8").decode(new Uint8Array(event.data));
                }

                this.processText(text);
            };
        } catch (e) {
            console.error('[ExerSyncKit] Exception during connection:', e);
        }
    }

    disconnect() {
        this.connectedConrollers = [];
        if (this.reconnectTimeout) {
            clearTimeout(this.reconnectTimeout);
            this.reconnectTimeout = null;
        }
        if (this.pendingConnectTimer) {
            clearTimeout(this.pendingConnectTimer);
            this.pendingConnectTimer = null;
        }
        this.connectGeneration++;
        if (this.socket) {
            this.socket.close();
            this.socket = null;
        }
        this.buffer = '';
        if (this.lifecycleState !== 'cooldown' && this.lifecycleState !== 'stopping') {
            this.setState('stopped');
        }
    }

    private scheduleReconnect() {
        // After first onopen, serverStarted is true. Before that, processLaunchOk means we launched the EXE and should keep retrying.
        if (this.reconnectTimeout || this.isManualDisconnect) return;
        if (!this.serverStarted && !this.processLaunchOk) return;

        console.log(`[ExerSyncKit] Connection lost. Retrying in 3 seconds...`);
        this.reconnectTimeout = setTimeout(() => {
            this.reconnectTimeout = null;
            if (!this.isServerStillRunning()) {
                this.notifyServerUnavailable('Server process is not running.');
                return;
            }
            this.establishConnection();
        }, 3000);
    }

    private processText(text: string) {
        if (!text) return;
        this.buffer += text;
        let newlineIndex: number;
        while ((newlineIndex = this.buffer.indexOf('\n')) >= 0) {
            const line = this.buffer.substring(0, newlineIndex).trim();
            this.buffer = this.buffer.substring(newlineIndex + 1);
            if (line === '') continue;
            try {
                const data = JSON.parse(line);
                const msgType = data.Type || data.type;
                const pId = data.PlayerId !== undefined ? data.PlayerId : (data.playerId !== undefined ? data.playerId : -1); // Get the player ID from the status message
                console.log('[ExerSyncKit] Received data type:', msgType);
                // Check if this is a system status message
                if (msgType === 'status') {
                    if (data.value === 'DISCONNECTED') {
                        console.warn(`[ExerSyncKit] Player ${pId} Lost`);
                        this.connectedConrollers = this.connectedConrollers.filter(id => id !== pId);
                        this.abortOngoingTransfer();
                        this.onControllerDisconnected?.(pId);
                    } else if (data.value === 'CONNECTED') {
                        console.log(`[ExerSyncKit] Player ${pId} Connected`);
                        if (!this.connectedConrollers.includes(pId)) {
                            this.connectedConrollers.push(pId);
                        }
                        this.onControllerConnected?.(pId);
                        // console.log('custom layout:', this.myPredefinedLayout);
                        if (this.myPredefinedLayout !== null) {
                            this.sendCommand(pId, `CONNECT_GAME:${this.gameId}:${this.version}`);
                        }
                    }
                } else if (msgType === 'command') {
                    if (data.value === 'PAUSE') {
                        this.onPause?.(); 
                    } else if (data.value === 'RESUME') {
                        this.onResume?.();
                    } else if (data.value === 'NEED_LAYOUT') {
                        console.log(`[ExerSyncKit] Player ${pId} needs layout. Sending...`);
                        if (this.myPredefinedLayout) {
                            this.sendLayout(pId, this.myPredefinedLayout);
                        }
                    }
                } else if (msgType === 'stepCount') {
                    const value = data.value ?? data.Value ?? 0;
                    const rid = data.requestId ?? data.RequestId;
                    if (this.pendingStepResolve &&
                        (!rid || rid === this.pendingStepRequestId)) {
                        this.pendingStepResolve(value);
                        this.pendingStepResolve = null;
                        this.pendingStepRequestId = null;
                    }
                } else if (msgType === 'geotagImage') {
                    const rid = data.requestId ?? data.RequestId;
                    if (this.pendingGeotagResolve &&
                        (!rid || rid === this.pendingGeotagRequestId)) {
                        this.pendingGeotagResolve({
                            success: data.success ?? data.Success ?? false,
                            exportPath: data.exportPath ?? data.ExportPath ?? '',
                            error: data.error ?? data.Error ?? '',
                        });
                        this.pendingGeotagResolve = null;
                        this.pendingGeotagRequestId = null;
                    }
                } else if (msgType === 'input') {
                    const st: InputState = {
                        PlayerId: pId,
                        JoyLX: data.joyLX ?? data.JoyLX ?? 0,
                        JoyLY: data.joyLY ?? data.JoyLY ?? 0,
                        JoyRX: data.joyRX ?? data.JoyRX ?? 0,
                        JoyRY: data.joyRY ?? data.JoyRY ?? 0,
                        Buttons: data.buttons ?? data.Buttons ?? 0,
                    };
                    this.onInput?.(pId, st);
                }
            } catch (e) {
                console.error('[ExerSyncKit] JSON parse error:', e);
            }
        }
    }

    private abortOngoingTransfer() {
        console.log("[ExerSyncKit] Aborting ongoing transfer...");
        this.currentTransferId++; // This causes the loop's 'sessionId !== currentTransferId' check to fail
        this.isSendingLargeData = false;
    }

    public getStepCounterAsync(playerId: number = -1, timeoutMs: number = 3000): Promise<number | null> {
        if (this.pendingStepResolve) {
            console.warn('[ExerSyncKit] getStepCounterAsync: request already in flight.');
            return Promise.resolve(null);
        }
        const reqId = Math.random().toString(36).slice(2, 10);
        return new Promise((resolve) => {
            this.pendingStepResolve = resolve;
            this.pendingStepRequestId = reqId;
            this.sendCommand(playerId, `GET_STEP_COUNT:${reqId}`);
            setTimeout(() => {
                if (this.pendingStepRequestId === reqId) {
                    this.pendingStepResolve = null;
                    this.pendingStepRequestId = null;
                    resolve(null);
                }
            }, timeoutMs);
        });
    }

    public resetStepCounter(playerId: number = -1) {
        this.sendCommand(playerId, 'RESET_STEP_COUNT'); 
    }

    public exportGeotaggedImageAsync(
        latitude: number,
        longitude: number,
        exportPath: string,
        sourceImagePath?: string | null,
        timeoutMs: number = 15000
    ): Promise<GeotagImageExportResult | null> {
        if (this.pendingGeotagResolve) {
            console.warn('[ExerSyncKit] exportGeotaggedImageAsync: request already in flight.');
            return Promise.resolve(null);
        }
        if (!exportPath?.trim()) {
            return Promise.resolve({ success: false, exportPath: '', error: 'exportPath is required.' });
        }

        const reqId = Math.random().toString(36).slice(2, 10);
        const payload = JSON.stringify({
            requestId: reqId,
            lat: latitude,
            lon: longitude,
            exportPath,
            sourcePath: sourceImagePath?.trim() ? sourceImagePath.trim() : null,
        });

        return new Promise((resolve) => {
            this.pendingGeotagResolve = resolve;
            this.pendingGeotagRequestId = reqId;
            this.sendCommand(-2, `GEOTAG_IMAGE:${payload}`);
            setTimeout(() => {
                if (this.pendingGeotagRequestId === reqId) {
                    this.pendingGeotagResolve = null;
                    this.pendingGeotagRequestId = null;
                    console.warn('[ExerSyncKit] exportGeotaggedImageAsync timed out.');
                    resolve(null);
                }
            }, timeoutMs);
        });
    }

    public sendCommand(pId: number, command: string) {
        if (this.socket && this.socket.readyState === WebSocket.OPEN) {
            let payload: string;
            if (pId === -2) {
                // Case 3: System command for the Server
                payload = `SYSTEM:${command}`;
            } else {
                // Case 1 & 2: Specific Controller (0, 1, 2...) or Broadcast (-1)
                payload = `TARGET:${pId}:${command}`;
            }
            this.socket.send(payload);
            if (pId === -1) {
                console.log(`[ExerSyncKit] Broadcast command sent: ${command}`);
            } else {
                console.log(`[ExerSyncKit] Targeted command sent to Player ${pId}: ${command}`);
            }
        } else {
            console.warn('[ExerSyncKit] Cannot send command - WebSocket not open');
        }
    }

    public async sendLayout(targetPlayerId: number, layoutData: any) {
        if (this.isSendingLargeData) {
            console.warn('[ExerSyncKit] Blocked sendLayout: A large transfer is already in progress.');
            return;
        }

        // Wrap the layout in a standard protocol so the server knows what to do with it
        var message = { gameId: this.gameId, version: this.version, ...layoutData };
        
        const jsonString = JSON.stringify(message);
        
        if (new TextEncoder().encode(`LAYOUT:${jsonString}`).length > 400) {
            console.log(`[ExerSyncKit] Large layout detected (${jsonString.length} chars). Using chunked sending.`);
            await this.sendLargeData(targetPlayerId, jsonString);
        } else {
            this.sendCommand(targetPlayerId, `LAYOUT:${jsonString}`);
        }
    }

    public async sendLargeData(targetPlayerId: number, fullString: string) {
        if (this.isSendingLargeData) return;

        this.currentTransferId++; // Increment ID for this specific transfer
        const sessionId = this.currentTransferId;

        this.isSendingLargeData = true;
        const CHUNK_SIZE = 500; // Safe limit
        const totalChunks = Math.ceil(fullString.length / CHUNK_SIZE);

        try {
            // Signal Start
            this.sendCommand(targetPlayerId, "START_MSG");

            for (let i = 0; i < totalChunks; i++) {
                // CHECK: If the ID has changed, another process stopped this one
                if (sessionId !== this.currentTransferId) {
                    console.warn("[ExerSyncKit] Transfer aborted: Session changed.");
                    return; 
                }

                const start = i * CHUNK_SIZE;
                const end = Math.min(start + CHUNK_SIZE, fullString.length);
                const chunk = fullString.substring(start, end);
                
                // Send the chunk prefixed so the phone knows it's data
                this.sendCommand(targetPlayerId, `CHUNK:${chunk}`);
                
                // Small delay to prevent flooding the bridge/BLE buffer
                await new Promise(resolve => setTimeout(resolve, 50));
            }
            
            // Final check before sending end message
            if (sessionId === this.currentTransferId) {
                this.sendCommand(targetPlayerId, "END_MSG");
            }
        } catch (e) {
            console.error("[ExerSyncKit] Error during chunked send:", e);
        } finally {
            // Only release the lock if we are still the "active" session
            if (sessionId === this.currentTransferId) {
                this.isSendingLargeData = false;
                console.log("[ExerSyncKit] Lock Released - Chunk Transfer Complete");
            }
        }
    }

    public async assetToData(asset: any): Promise<string> {
        // Handle PNG/JPG (ImageAsset) for Windows EXE
        if (JSB) {  // Check if we are running in a Native/Windows environment
            try {
                // Get the actual path to the file on your hard drive
                const path = asset.nativeUrl; 
                // Read the file as raw binary data
                const buffer = native.fileUtils.getDataFromFile(path);
                
                if (buffer) {
                    const base64 = this.arrayBufferToBase64(buffer);
                    return `data:image/png;base64,${base64}`;
                }
            } catch (e) {
                console.error("Windows File Reading Failed:", e);
            }
        }
        // Method for Web/other platforms
        const rawBuffer = asset._data || asset._nativeAsset;
        if (rawBuffer) {
            const base64 = this.arrayBufferToBase64(rawBuffer);
            return `data:image/png;base64,${base64}`;
        }
        return "";
    }

    private arrayBufferToBase64(buffer: any): string {
        const bytes = new Uint8Array(buffer);
        let binary = '';
        const len = bytes.byteLength;
        for (let i = 0; i < len; i++) {
            binary += String.fromCharCode(bytes[i]);
        }
        // btoa is available in Cocos's JS engine even on Windows
        return btoa(binary);
    }

    public static formatToProtocolColor(color: Color | string): string {
        if (typeof color === 'string') {
            let hex = color.replace('#', '').replace('0x', '').toUpperCase();
        
            // If developer provided RGB, add the "FF" (Opaque) prefix automatically
            if (hex.length === 6) {
                hex = "FF" + hex;
            }
            return hex;
        }
        
        // Convert Cocos Color (RGBA) to Protocol Standard (AARRGGBB)
        const a = color.a.toString(16).padStart(2, '0');
        const r = color.r.toString(16).padStart(2, '0');
        const g = color.g.toString(16).padStart(2, '0');
        const b = color.b.toString(16).padStart(2, '0');
        
        return `${a}${r}${g}${b}`.toUpperCase();
    }

    public shutdownServer() {
        if (this.serverStarted || this.processLaunchOk) {
            this.setState('stopping');
            this.isManualDisconnect = true;
            this.processLaunchOk = false;
            this.startRestartCooldown();
            console.log('[ExerSyncKit] Initiating safe shutdown via Native Bridge...');
            if (this.socket && this.socket.readyState === WebSocket.OPEN) {
                this.sendCommand(-2, "SHUTDOWN");
            }
            if (typeof closeExternalExe !== 'undefined') {
                const closed = closeExternalExe();
                console.log(`[ExerSyncKit] closeExternalExe result: ${closed}`);
                if (typeof isExternalExeAlive !== 'undefined') {
                    const alive = isExternalExeAlive();
                    console.log(`[ExerSyncKit] Server alive after close request: ${alive}`);
                }
            }

            this.disconnect();
            this.serverStarted = false;
            console.log(`[ExerSyncKit] Restart cool-down started (${(ExerSyncKit.minRestartDelayMs / 1000).toFixed(1)}s).`);
        } else {
            const cooldownMs = this.getRemainingCooldownMs();
            if (cooldownMs > 0) {
                this.setState('cooldown', cooldownMs);
                this.onCooldown?.(cooldownMs);
            } else {
                this.setState('stopped');
            }
        }
        this.unbindOptionsCallbacks();
    }

    public disableAsync(): Promise<void> {
        return new Promise((resolve) => {
            this.shutdownServer();
            setTimeout(resolve, 100);
        });
    }

    public getControllerCount(): number {
        return this.connectedConrollers.length;
    }

    public isPlayerConnected(playerId: number): boolean {
        return this.connectedConrollers.includes(playerId);
    }

    public broadcastCommand(command: string) {
        this.sendCommand(-1, command);
    }

    public triggerVibration(playerId: number = -1) {
        this.sendCommand(playerId, "TRIGGER_VIBRATION");
    }

    public enableStep(playerId: number = -1) {
        this.sendCommand(playerId, "ENABLE_STEP");
    }

    public disableStep(playerId: number = -1) {
        this.sendCommand(playerId, "DISABLE_STEP");
    }

    public enableSteering(playerId: number = -1) {
        this.sendCommand(playerId, "ENABLE_STEERING");
    }

    public disableSteering(playerId: number = -1) {
        this.sendCommand(playerId, "DISABLE_STEERING");
    }
}