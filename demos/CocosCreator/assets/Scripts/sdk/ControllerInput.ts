import { Color, native, sys } from 'cc';
import { JSB } from 'cc/env';

declare const GetCurrentProcessId: () => number;

export interface InputState {
    PlayerId: number;
    JoyLX: number;
    JoyLY: number;
    JoyRX: number;
    JoyRY: number;
    Buttons: number;
}

export const DefaultButtonMasks = {
    Cross: 1 << 12,
    Circle: 1 << 13,
    Square: 1 << 14,
    Triangle: 1 << 15,
    Up: 1 << 0,
    Down: 1 << 1,
    Left: 1 << 2,
    Right: 1 << 3,
};

export type ControllerServerState = 'stopped' | 'starting' | 'running' | 'stopping' | 'cooldown';

export class ControllerInput {
    private serverName: string = "Server.Ble.exe";
    private socket: WebSocket | null = null;
    private buffer: string = '';
    /** BLE stack needs a short cool-down after shutdown before relaunch is stable. Shared across instances. */
    private static readonly minRestartDelayMs = 5000;
    private static cooldownUntilMs = 0;

    public onInput: ((playerId: number, state: InputState) => void) | null = null;
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

    private setState(state: ControllerServerState, remainingCooldownMs?: number) {
        if (this.lifecycleState === state) return;
        this.lifecycleState = state;
        this.onStateChanged?.(state, remainingCooldownMs);
    }

    public getRemainingCooldownMs(): number {
        return Math.max(0, ControllerInput.cooldownUntilMs - Date.now());
    }

    public getState(): ControllerServerState {
        return this.lifecycleState;
    }

    public isInCooldown(): boolean {
        return this.getRemainingCooldownMs() > 0;
    }

    private startRestartCooldown() {
        ControllerInput.cooldownUntilMs = Date.now() + ControllerInput.minRestartDelayMs;
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
            console.log(`[SDK] launchServer ignored: server is already ${this.lifecycleState}.`);
            return true;
        }
        if (this.lifecycleState === 'stopping') {
            console.warn('[SDK] launchServer ignored: server is currently stopping.');
            return false;
        }
        const cooldownMs = this.getRemainingCooldownMs();
        if (cooldownMs > 0) {
            const sec = (cooldownMs / 1000).toFixed(1);
            console.warn(`[SDK] Launch blocked by cool-down (${sec}s left). This avoids rapid BLE restart failures.`);
            this.onCooldown?.(cooldownMs);
            this.setState('cooldown', cooldownMs);
            this.processLaunchOk = false;
            return false;
        }
        this.setState('starting');
        if (sys.isNative && sys.os === sys.OS.WINDOWS) {
            try {
                const rootPath = native.fileUtils.getDefaultResourceRootPath();
                const fullPath = (rootPath + this.serverName).replace(/\//g, "\\");
                
                const gamePid = (window as any).getGamePid ? (window as any).getGamePid() : 0;
                const commandLine = `"${fullPath}" ${gamePid}`;

                console.log("[SDK] Attempting to launch server:", commandLine);

                // Trigger the C++ bridge
                if ((window as any).launchExternalExe) {
                    const didStart = (window as any).launchExternalExe(commandLine);

                    if (didStart) {
                        console.log("[SDK] Server process launched and still running (native check passed).");
                        this.processLaunchOk = true;
                        this.setState('running');
                    } else {
                        console.error(
                            "[SDK] Server did not stay running. Check: (1) Server.Ble.exe exists next to game data, " +
                            "(2) run it manually from that folder to see errors, (3) rebuild native ble_controller after C++ changes."
                        );
                        console.error("[SDK] Intended path:", fullPath);
                        this.processLaunchOk = false;
                        this.setState('stopped');
                    }
                    return didStart;
                } else {
                    console.error("[SDK] launchExternalExe not found! Is the C++ bridge linked?");
                    this.setState('stopped');
                    return false;
                }
            } catch (e) {
                console.error("[SDK] Failed to launch server:", e);
                this.setState('stopped');
                return false;
            }
        } else {
            console.warn("[SDK] launchServer ignored: Not running on Native Windows.");
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
            console.warn(`[ControllerInput] connect() blocked by cooldown (${sec}s left).`);
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
        console.log(`[ControllerInput] Attempting connection to ${this.currentUrl}...`);

        try {
            // Avoid passing an empty subprotocol list; some native WebSocket stacks behave badly with `[]`.
            this.socket = new WebSocket(this.currentUrl);
            this.socket.binaryType = "arraybuffer";

            this.socket.onopen = () => {
                console.log('[ControllerInput] Connected to controller server (WebSocket)');
                this.serverStarted = true;
                this.setState('running');
                this.onConnected?.();
            };

            this.socket.onclose = (event) => {
                console.log('[ControllerInput] Disconnected from server');
                console.log('   Code:', event.code);
                console.log('   Reason:', event.reason || '(no reason)');
                console.log('   Was clean:', event.wasClean);
                this.abortOngoingTransfer();
                this.socket = null;
                this.connectedConrollers = [];
                if (this.lifecycleState !== 'cooldown' && this.lifecycleState !== 'stopping') {
                    this.setState('stopped');
                }

                // TRIGGER RECONNECT
                if (!this.isManualDisconnect) {
                    this.onDisconnected?.();
                    this.scheduleReconnect();
                }
            };

            this.socket.onerror = (err) => {
                console.error('[ControllerInput] WebSocket error:', err);
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
            console.error('[ControllerInput] Exception during connection:', e);
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

        console.log(`[ControllerInput] Connection lost. Retrying in 3 seconds...`);
        this.reconnectTimeout = setTimeout(() => {
            this.reconnectTimeout = null;
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
                console.log('[ControllerInput] Received data type:', msgType);
                // Check if this is a system status message
                if (msgType === 'status') {
                    if (data.value === 'DISCONNECTED') {
                        console.warn(`[SDK] Player ${pId} Lost`);
                        this.connectedConrollers = this.connectedConrollers.filter(id => id !== pId);
                        this.abortOngoingTransfer();
                        this.onControllerDisconnected?.(pId);
                    } else if (data.value === 'CONNECTED') {
                        console.log(`[SDK] Player ${pId} Connected`);
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
                        console.log(`[SDK] Player ${pId} needs layout. Sending...`);
                        if (this.myPredefinedLayout) {
                            this.sendLayout(pId, this.myPredefinedLayout);
                        }
                    }
                } else if (msgType === 'input') {
                    // Otherwise, treat it as normal InputState
                    this.onInput?.(pId, data as InputState);
                }
            } catch (e) {
                console.error('[ControllerInput] JSON parse error:', e);
            }
        }
    }

    private abortOngoingTransfer() {
        console.log("[ControllerInput] Aborting ongoing transfer...");
        this.currentTransferId++; // This causes the loop's 'sessionId !== currentTransferId' check to fail
        this.isSendingLargeData = false;
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
                console.log(`[ControllerInput] Broadcast command sent: ${command}`);
            } else {
                console.log(`[ControllerInput] Targeted command sent to Player ${pId}: ${command}`);
            }
        } else {
            console.warn('[ControllerInput] Cannot send command - WebSocket not open');
        }
    }

    public async sendLayout(targetPlayerId: number, layoutData: any) {
        if (this.isSendingLargeData) {
            console.warn('[ControllerInput] Blocked sendLayout: A large transfer is already in progress.');
            return;
        }

        // Wrap the layout in a standard protocol so the server knows what to do with it
        var message = { gameId: this.gameId, version: this.version, ...layoutData };
        
        const jsonString = JSON.stringify(message);
        
        if (jsonString.length > 1000) {
            console.log(`[ControllerInput] Large layout detected (${jsonString.length} chars). Using chunked sending.`);
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
                    console.warn("[ControllerInput] Transfer aborted: Session changed.");
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
            console.error("[ControllerInput] Error during chunked send:", e);
        } finally {
            // Only release the lock if we are still the "active" session
            if (sessionId === this.currentTransferId) {
                this.isSendingLargeData = false;
                console.log("[ControllerInput] Lock Released - Chunk Transfer Complete");
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
            console.log('[SDK] Initiating safe shutdown via Native Bridge...');
            // Ask the server to shut itself down first so C# can run full cleanup.
            if (this.socket && this.socket.readyState === WebSocket.OPEN) {
                this.sendCommand(-2, "SHUTDOWN");
            }
            // 1. Trigger the C++ "Polite" Shutdown (CTRL+BREAK)
            // This is the most reliable way to ensure the C# CleanUp() runs.
            if ((window as any).closeExternalExe) {
                const closed = (window as any).closeExternalExe();
                console.log(`[SDK] closeExternalExe result: ${closed}`);
                if ((window as any).isExternalExeAlive) {
                    const alive = (window as any).isExternalExeAlive();
                    console.log(`[SDK] Server alive after close request: ${alive}`);
                }
            }

            // 2. Disconnect the local socket immediately
            this.disconnect();
            this.serverStarted = false;
            console.log(`[SDK] Restart cool-down started (${(ControllerInput.minRestartDelayMs / 1000).toFixed(1)}s).`);
        } else {
            const cooldownMs = this.getRemainingCooldownMs();
            if (cooldownMs > 0) {
                this.setState('cooldown', cooldownMs);
                this.onCooldown?.(cooldownMs);
            } else {
                this.setState('stopped');
            }
        }
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
}