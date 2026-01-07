import { InputState } from './InputState';

export class ControllerInput {
    private socket: WebSocket | null = null;
    private buffer: string = '';

    public onInput: ((state: InputState) => void) | null = null;
    public onConnected: (() => void) | null = null;
    public onDisconnected: (() => void) | null = null;
    public onError: ((err: any) => void) | null = null;

    private serverStarted = false;

    connect(url: string = 'ws://127.0.0.1:38421/controller') {
        this.disconnect();

        try {
            this.socket = new WebSocket(url, []);
            this.socket.binaryType = "arraybuffer";

            this.socket.onopen = () => {
                console.log('[ControllerInput] Connected to controller server (WebSocket)');
                this.onConnected?.();
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
                        this._processText(reader.result as string);
                    };
                    reader.readAsText(event.data);
                    return; 
                }

                this._processText(text);
            };

            this.socket.onclose = (event) => {
                console.log('[ControllerInput] Disconnected from server');
                console.log('   Code:', event.code);
                console.log('   Reason:', event.reason || '(no reason)');
                console.log('   Was clean:', event.wasClean);
                this.onDisconnected?.();
                this.socket = null;
            };

            this.socket.onerror = (err) => {
                console.error('[ControllerInput] WebSocket error:', err);
                this.onError?.(err);
                this.onDisconnected?.();
            };
        } catch (e) {
            console.error('[ControllerInput] Exception during connection:', e);
        }
    }

    disconnect() {
        if (this.socket) {
            this.socket.close();
            this.socket = null;
        }
        this.buffer = '';
    }

    private _processText(text: string) {
        if (!text) return;
        this.buffer += text;
        let newlineIndex: number;
        while ((newlineIndex = this.buffer.indexOf('\n')) >= 0) {
            const line = this.buffer.substring(0, newlineIndex).trim();
            this.buffer = this.buffer.substring(newlineIndex + 1);
            if (line === '') continue;
            try {
                const state: InputState = JSON.parse(line);
                this.onInput?.(state);
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
}