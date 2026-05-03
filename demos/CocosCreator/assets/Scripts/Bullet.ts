import { _decorator, Component, Node, Contact2DType, Collider, ICollisionEvent } from 'cc';
const { ccclass, property } = _decorator;

@ccclass('Bullet')
export class Bullet extends Component {
    onLoad() {
        // Get the collider on this bullet
        const collider = this.getComponent(Collider);
        if (collider) {
            // Listen for the "onCollisionEnter" event
            collider.on('onCollisionEnter', this.onCollision, this);
        }

        // Optional: Auto-destroy after 3 seconds if it hits nothing
        this.scheduleOnce(() => {
            if (this.node && this.node.isValid) {
                this.node.destroy();
            }
        }, 3);
    }

    private onCollision(event: ICollisionEvent) {
        // 'event.otherCollider' is what we hit
        console.log('Bullet hit: ' + event.otherCollider.node.name);
        const otherNode = event.otherCollider.node;
    
        // Look for the Health script on the NPC
        const health = otherNode.getComponent('Health') as any;
        if (health) {
            health.takeDamage();
        }

        // Destroy the bullet node immediately on impact
        this.node.destroy();
    }
}


