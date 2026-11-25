import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { AppSession, newAppSession } from '../app/AppSession';

export default class EntryAbility extends UIAbility {
  private session?: AppSession;
  onCreate(): void {
    const session = newAppSession();
    this.session = session;
    session.init(this.context).catch((e: Error) => session.error(e.message));
  }
  onWindowStageCreate(stage: window.WindowStage): void { stage.loadContent('pages/Index'); }
  onDestroy(): void { this.session?.stop().catch(() => {}); }
}
