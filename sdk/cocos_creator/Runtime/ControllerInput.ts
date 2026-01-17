import { InputState } from './InputState';

export class ControllerInput {
    private socket: WebSocket | null = null;
    private buffer: string = '';

    public onInput: ((state: InputState) => void) | null = null;
    public onPause: (() => void) | null = null;
    public onResume: (() => void) | null = null;
    public onConnected: (() => void) | null = null;
    public onDisconnected: (() => void) | null = null;
    public onControllerConnected: (() => void) | null = null;
    public onControllerDisconnected: (() => void) | null = null;
    public onError: ((err: any) => void) | null = null;

    private serverStarted = false;
    private reconnectTimeout: any = null;
    private currentUrl: string = '';
    private isManualDisconnect: boolean = false;

    connect(url: string = 'ws://127.0.0.1:38421/controller') {
        this.currentUrl = url;
        this.isManualDisconnect = false;
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
                this.onDisconnected?.();
                this.socket = null;

                // TRIGGER RECONNECT
                if (!this.isManualDisconnect) {
                    this.scheduleReconnect();
                }
            };

            this.socket.onerror = (err) => {
                console.error('[ControllerInput] WebSocket error:', err);
                this.onError?.(err);
                this.onDisconnected?.();
            };

            this.socket.onmessage = (event) => {
                let text = "";

                if (typeof event.data === 'string') {
                    text = event.data;
                } else if (event.data instanceof ArrayBuffer) {
                    // Native Cocos usually returns ArrayBuffer for binary
                    text = new TextDecoder("utf-8").decode(new Uint8Array(event.data));
                } else if (event.data instanceof Blob) {
                    // If it's a blob, we still try to use TextDecoder after converting
                    // But many native environments skip Blob and go straight to ArrayBuffer
                    console.warn('[ControllerInput] Received Blob - this might be slow on native');
                    const reader = new FileReader();
                    reader.onload = () => {
                        this.processText(reader.result as string);
                    };
                    reader.readAsText(event.data);
                    return; 
                }

                this.processText(text);
            };
        } catch (e) {
            console.error('[ControllerInput] Exception during connection:', e);
        }
    }

    disconnect() {
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
        if (this.reconnectTimeout || this.isManualDisconnect) return; // Already waiting

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
                console.log('[ControllerInput] Received data type:', data.type);
                // Check if this is a system status message
                if (data.type === 'status') {
                    if (data.value === 'PHONE_DISCONNECTED') {
                        console.warn('[SDK] Phone Heartbeat Lost');
                        this.onControllerDisconnected?.();
                    } else if (data.value === 'PHONE_CONNECTED') {
                        console.log('[SDK] Phone Heartbeat Active');
                        this.onControllerConnected?.();
                    }
                } else if (data.type === 'command') {
                    if (data.value === 'PAUSE') {
                        // Trigger whatever event or callback handles pausing
                        this.onPause?.(); 
                    } else if (data.value === 'RESUME') {
                        this.onResume?.();
                    }
                } else {
                    // Otherwise, treat it as normal InputState
                    this.onInput?.(data as InputState);
                }
            } catch (e) {
                console.error('[ControllerInput] JSON parse error:', e);
            }
        }
    }

    public sendCommand(command: string) {
        if (this.socket && this.socket.readyState === WebSocket.OPEN) {
            this.socket.send(command);
            console.log('[ControllerInput] Sent command:', command);
        } else {
            console.warn('[ControllerInput] Cannot send command - WebSocket not open');
        }
    }

    public shutdownServer() {
        if (this.serverStarted) {
            console.log('[ControllerInput] Requesting server shutdown...');
            // Assuming your external server listens for a JSON command or string
            this.sendCommand("SHUTDOWN");
            
            // Give it a moment to process before we close the local socket
            setTimeout(() => {
                this.isManualDisconnect = true;
                this.disconnect();
            }, 1000);
        }
    }
}