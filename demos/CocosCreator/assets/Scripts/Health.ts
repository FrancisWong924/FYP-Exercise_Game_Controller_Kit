import { _decorator, Component, Node, MeshRenderer, Color, Material } from 'cc';
const { ccclass, property } = _decorator;

@ccclass('Health')
export class Health extends Component {
    @property
    maxHits: number = 3;

    private _currentHits: number = 0;
    private _meshRenderer: MeshRenderer = null!;
    private _materialInstance: Material = null!;
    private _originalColor: Color = new Color(255, 255, 255, 255);
    private _hitColor: Color = new Color(255, 0, 0, 255); // Pure Red

    onLoad() {
        this._currentHits = this.maxHits;
        this._meshRenderer = this.getComponent(MeshRenderer)!;
        // Use .material (not .sharedMaterial) to create a unique instance for this NPC
        if (this._meshRenderer && this._meshRenderer.material) {
            this._materialInstance = this._meshRenderer.material;
            const currentColor = this._materialInstance.getProperty('mainColor') as Color;
            if (currentColor) {
                this._originalColor.set(currentColor);
            }
        }
    }

    public takeDamage() {
        if (this._currentHits <= 0) return; // Already dead
        this._currentHits--;

        // 1. Flash Red
        if (this._materialInstance) {
            this._materialInstance.setProperty('mainColor', this._hitColor);
            this.scheduleOnce(() => {
                if (this.node && this.node.isValid) {
                    this._materialInstance.setProperty('mainColor', this._originalColor);
                }
            }, 0.15);
        }

        // 2. Check for Death
        if (this._currentHits <= 0) {
            this.die();
        }
    }

    private die() {
        console.log("NPC Destroyed!");
        // You could play a sound or spawn particles here before destroying
        this.node.destroy();
    }
}


