import { Color, native, sys } from 'cc';
import { JSB } from 'cc/env';

export interface InputState {
    PlayerId: number;
    JoyLX: number;
    JoyLY: number;
    JoyRX: number;
    JoyRY: number;
    Buttons: number;
    Stepping: number;
    Steering: number;
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

export class ControllerInput {
    private socket: WebSocket | null = null;
    private buffer: string = '';

    public onInput: ((playerId: number, state: InputState) => void) | null = null;
    public onPause: (() => void) | null = null;
    public onResume: (() => void) | null = null;
    public onConnected: (() => void) | null = null;
    public onDisconnected: (() => void) | null = null;
    public onControllerConnected: ((playerId: number) => void) | null = null;
    public onControllerDisconnected: ((playerId: number) => void) | null = null;
    public onError: ((err: any) => void) | null = null;
    public connectedConrollers: number[] = [];

    private serverStarted = false;
    private reconnectTimeout: any = null;
    private currentUrl: string = '';
    private isManualDisconnect: boolean = false;

    private gameId: string = '';
    private version: number = 1;
    private myPredefinedLayout: any = null;
    private isSendingLargeData: boolean = false;
    private currentTransferId: number = 0;

    public launchServer(relativePath: string): boolean {
        if (sys.isNative && sys.os === sys.OS.WINDOWS) {
            try {
                // 1. Get the base path
                const rootPath = native.fileUtils.getDefaultResourceRootPath();
                
                // 2. Combine and format for Windows
                const fullPath = (rootPath + relativePath).replace(/\//g, "\\");
                
                console.log("[SDK] Attempting to launch server:", fullPath);

                // 3. Trigger the C++ bridge
                if ((window as any).launchExternalExe) {
                    const didStart = (window as any).launchExternalExe(fullPath);

                    if (didStart) {
                        console.log("[SDK] Server process started successfully.");
                    } else {
                        console.error("[SDK] Server failed to start. Path might be wrong:", fullPath);
                    }
                    return didStart;
                } else {
                    console.error("[SDK] launchExternalExe not found! Is the C++ bridge linked?");
                    return false;
                }
            } catch (e) {
                console.error("[SDK] Failed to launch server:", e);
                return false;
            }
        } else {
            console.warn("[SDK] launchServer ignored: Not running on Native Windows.");
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
        // Clear any pending reconnects
        if (this.reconnectTimeout) {
            clearTimeout(this.reconnectTimeout);
            this.reconnectTimeout = null;
        }
        this.establishConnection();
    }

    private establishConnection() {
        this.disconnect();
        console.log(`[ControllerInput] Attempting connection to ${this.currentUrl}...`);

        try {
            this.socket = new WebSocket(this.currentUrl, []);
            this.socket.binaryType = "arraybuffer";

            this.socket.onopen = () => {
                console.log('[ControllerInput] Connected to controller server (WebSocket)');
                this.serverStarted = true;
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
        if (this.socket) {
            this.socket.close();
            this.socket = null;
        }
        this.buffer = '';
    }

    private scheduleReconnect() {
        if (this.reconnectTimeout || !this.serverStarted || this.isManualDisconnect) return; // Already waiting

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
        const message = {
            gameId: this.gameId,
            version: this.version,
            data: layoutData
        };

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
        if (this.serverStarted) {
            this.isManualDisconnect = true;
            console.log('[ControllerInput] Requesting server shutdown...');
            // Assuming your external server listens for a JSON command or string
            this.sendCommand(-2, "SHUTDOWN");
            
            // Give it a moment to process before we close the local socket
            setTimeout(() => {
                this.disconnect();
            }, 1000);
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