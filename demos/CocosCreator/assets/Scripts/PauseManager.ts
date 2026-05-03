import { _decorator, Component, input, Input, EventKeyboard, KeyCode, game } from 'cc';
import { GameSettings } from './GameSettings';
import { PauseUI } from './PauseUI';  // Adjust path
const { ccclass, property } = _decorator;

@ccclass('PauseManager')
export class PauseManager extends Component {
    @property(PauseUI)
    pauseUI: PauseUI = null!;  // Drag PausePanel node here

    onLoad() {
        input.on(Input.EventType.KEY_DOWN, this.onKeyDown, this);
    }

    onDestroy() {
        input.off(Input.EventType.KEY_DOWN, this.onKeyDown, this);
    }

    private onKeyDown(event: EventKeyboard) {
        if (event.keyCode === KeyCode.ESCAPE) {
            if (GameSettings.instance.isPaused) {
                this.pauseUI.hide();
            } else {
                this.pauseUI.show();
            }
            event.propagationStopped = true;  // Prevent other handlers
        }
    }
}