import game from 'libentry.so';
import { Cell, computeMove, MovePlan, N, Tile } from '../game/SlideEngine';

// Go 侧返回的游戏状态 JSON 结构。
interface GameState {
  board: number[][];
  score: number;
  over: boolean;
  won: boolean;
}

// 棋盘几何（与背景网格保持一致）：内边距 + N 个格子 + 间隙。
const CELL: number = 70;
const GAP: number = 8;
const PAD: number = 8;
const BOARD: number = PAD * 2 + CELL * N + GAP * (N - 1);
const SLIDE_MS: number = 120; // 滑动时长
const POP_MS: number = 120; // 合并 / 出现的弹跳时长

// 第 idx 个格子（行或列）的像素偏移。
function cellPos(idx: number): number {
  return PAD + idx * (CELL + GAP);
}

function tileColor(v: number): string {
  const map: Record<string, string> = {
    '0': '#CDC1B4', '2': '#EEE4DA', '4': '#EDE0C8', '8': '#F2B179',
    '16': '#F59563', '32': '#F67C5F', '64': '#F65E3B', '128': '#EDCF72',
    '256': '#EDCC61', '512': '#EDC850', '1024': '#EDC53F', '2048': '#EDC22E'
  };
  const c: string | undefined = map[v.toString()];
  return c !== undefined ? c : '#3C3A32';
}

function tileFontColor(v: number): string {
  return v <= 4 ? '#776E65' : '#F9F6F2';
}

function tileFontSize(v: number): number {
  if (v >= 1024) {
    return 24;
  }
  if (v >= 128) {
    return 30;
  }
  return 38;
}

// 单个方块：绝对定位。@ObjectLink 监听 tile 的 row/col/value/scale 变化，
// 配合外层 animateTo 实现滑动与弹跳动画。
@Component
struct TileView {
  @ObjectLink tile: Tile;

  build() {
    Stack() {
      Text(this.tile.value.toString())
        .fontSize(tileFontSize(this.tile.value))
        .fontWeight(FontWeight.Bold)
        .fontColor(tileFontColor(this.tile.value))
    }
    .width(CELL)
    .height(CELL)
    .backgroundColor(tileColor(this.tile.value))
    .borderRadius(6)
    .position({ x: cellPos(this.tile.col), y: cellPos(this.tile.row) })
    .scale({ x: this.tile.scale, y: this.tile.scale })
  }
}

@Entry
@Component
struct Index {
  @State tiles: Tile[] = [];
  @State score: number = 0;
  @State over: boolean = false;
  @State won: boolean = false;
  private nextId: number = 1;

  aboutToAppear(): void {
    this.restart();
  }

  restart(): void {
    const go: GameState = JSON.parse(game.newGame()) as GameState;
    this.score = go.score;
    this.over = go.over;
    this.won = go.won;
    this.tiles = this.tilesFromBoard(go.board);
    this.popToOne();
  }

  doMove(dir: number): void {
    if (this.over || this.tiles.length === 0) {
      return;
    }

    const plan: MovePlan = computeMove(this.tiles, dir);
    const go: GameState = JSON.parse(game.move(dir)) as GameState;

    if (!plan.moved) {
      this.score = go.score;
      this.over = go.over;
      this.won = go.won;
      return;
    }

    // 阶段一：所有方块（含将被吸收者）滑向目标格。直接修改 @Observed 属性并由 animateTo 过渡位置。
    this.getUIContext().animateTo({
      duration: SLIDE_MS,
      curve: Curve.EaseInOut,
      onFinish: () => this.commitMove(plan, go)
    }, () => {
      for (const t of this.tiles) {
        const dest: Cell | undefined = plan.targets.get(t.id);
        if (dest !== undefined) {
          t.row = dest.row;
          t.col = dest.col;
        }
      }
    });
  }

  // 阶段二：移除被吸收方块、幸存者数值翻倍并放大、补齐随机新增方块，再回弹缩放。
  commitMove(plan: MovePlan, go: GameState): void {
    // 移除被合并吸收的方块（保留其余对象引用，子组件不重建）
    this.tiles = this.tiles.filter((t: Tile): boolean => !plan.absorbed.has(t.id));

    // 合并幸存者：数值翻倍并瞬间放大（随后回弹形成弹跳）
    for (const t of this.tiles) {
      const nv: number | undefined = plan.newValues.get(t.id);
      if (nv !== undefined) {
        t.value = nv;
        t.merged = true;
        t.scale = 1.2;
      }
    }

    // 对比 Go 盘面，定位本步随机生成的方块（盘面中多出的那个格子）。
    const after: number[][] = this.boardFromTiles(this.tiles);
    for (let i = 0; i < N; i++) {
      for (let j = 0; j < N; j++) {
        if (go.board[i][j] !== 0 && go.board[i][j] !== after[i][j]) {
          this.tiles = this.tiles.concat([new Tile(this.nextId++, i, j, go.board[i][j], 0.1, true, false)]);
        }
      }
    }

    this.score = go.score;
    this.over = go.over;
    this.won = go.won;
    this.popToOne();
  }

  // 把各方块的 scale 回弹到 1（合并 1.2→1、新增 0.1→1），形成「数值改变 / 出现」弹跳动画。
  popToOne(): void {
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: POP_MS, curve: Curve.EaseOut }, () => {
        for (const t of this.tiles) {
          t.scale = 1;
        }
      });
    }, 16);
  }

  tilesFromBoard(board: number[][]): Tile[] {
    const out: Tile[] = [];
    for (let i = 0; i < N; i++) {
      for (let j = 0; j < N; j++) {
        if (board[i][j] !== 0) {
          out.push(new Tile(this.nextId++, i, j, board[i][j], 0.1, true, false));
        }
      }
    }
    return out;
  }

  boardFromTiles(tiles: Tile[]): number[][] {
    const b: number[][] = [];
    for (let i = 0; i < N; i++) {
      const row: number[] = [];
      for (let j = 0; j < N; j++) {
        row.push(0);
      }
      b.push(row);
    }
    for (const t of tiles) {
      b[t.row][t.col] = t.value;
    }
    return b;
  }

  // 背景网格：固定的 N×N 空格。
  @Builder
  gridBackground() {
    Column({ space: GAP }) {
      ForEach([0, 1, 2, 3], (r: number) => {
        Row({ space: GAP }) {
          ForEach([0, 1, 2, 3], (c: number) => {
            Stack()
              .width(CELL)
              .height(CELL)
              .backgroundColor('#CDC1B4')
              .borderRadius(6)
          }, (c: number) => c.toString())
        }
      }, (r: number) => r.toString())
    }
    .padding(PAD)
  }

  build() {
    Column({ space: 14 }) {
      Text('2048')
        .fontSize(48)
        .fontWeight(FontWeight.Bold)
        .fontColor('#776E65')
      Text('逻辑由 Go 实现 · 界面 ArkTS · NAPI 桥接')
        .fontSize(13)
        .fontColor('#998A7B')

      Row({ space: 12 }) {
        Column() {
          Text('得分').fontSize(12).fontColor('#EEE4DA')
          Text(this.score.toString()).fontSize(22).fontWeight(FontWeight.Bold).fontColor(Color.White)
        }
        .padding({ left: 18, right: 18, top: 6, bottom: 6 })
        .backgroundColor('#BBADA0')
        .borderRadius(6)

        Button('新游戏')
          .backgroundColor('#8F7A66')
          .fontColor(Color.White)
          .onClick(() => this.restart())
      }

      // 棋盘：背景网格 + 绝对定位的方块层
      Stack({ alignContent: Alignment.TopStart }) {
        this.gridBackground()
        ForEach(this.tiles, (t: Tile) => {
          TileView({ tile: t })
        }, (t: Tile) => t.id.toString())
      }
      .width(BOARD)
      .height(BOARD)
      .backgroundColor('#BBADA0')
      .borderRadius(8)

      if (this.over) {
        Text(this.won ? '🎉 你赢了！' : '游戏结束').fontSize(20).fontColor('#776E65').fontWeight(FontWeight.Bold)
      } else if (this.won) {
        Text('🎉 达成 2048，可继续挑战').fontSize(16).fontColor('#776E65')
      }

      Text('在棋盘上滑动 ←↑→↓ 来移动').fontSize(12).fontColor('#998A7B')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#FAF8EF')
    .gesture(
      PanGesture({ distance: 15 })
        .onActionEnd((event: GestureEvent) => {
          const dx: number = event.offsetX;
          const dy: number = event.offsetY;
          if (Math.abs(dx) > Math.abs(dy)) {
            this.doMove(dx > 0 ? 1 : 3); // 右 / 左
          } else {
            this.doMove(dy > 0 ? 2 : 0); // 下 / 上
          }
        })
    )
  }
}
