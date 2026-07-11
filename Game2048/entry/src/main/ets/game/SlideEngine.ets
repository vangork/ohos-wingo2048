// 2048 滑动计算：纯函数模块。
// 依据当前方块布局与方向，推导每个方块的目标格子与合并信息，用于驱动滑动 / 合并动画。
// 棋盘真值（最终盘面、得分、胜负）仍以 Go 侧 libentry.so 为准，本模块只负责动画推导。
// 方向编码与 Go 保持一致：0=上 1=右 2=下 3=左

export const N: number = 4; // 棋盘边长

// 棋盘格子坐标。
export class Cell {
  row: number;
  col: number;

  constructor(row: number, col: number) {
    this.row = row;
    this.col = col;
  }
}

// 一个可见方块。带稳定 id 以便 ForEach 跨帧复用同一节点；@Observed 使其属性变化
// 能被子组件的 @ObjectLink 监听，从而对位置 / 缩放做过渡动画。
@Observed
export class Tile {
  id: number;
  row: number;
  col: number;
  value: number;
  scale: number; // 渲染缩放，用于出现 / 合并的弹跳动画
  isNew: boolean; // 本步新生成
  merged: boolean; // 本步由合并产生

  constructor(id: number, row: number, col: number, value: number,
    scale: number, isNew: boolean, merged: boolean) {
    this.id = id;
    this.row = row;
    this.col = col;
    this.value = value;
    this.scale = scale;
    this.isNew = isNew;
    this.merged = merged;
  }
}

// 一次移动的推导结果（不含随机新增方块，新增方块由调用方对比 Go 盘面后补齐）。
export class MovePlan {
  moved: boolean; // 是否发生任何移动 / 合并
  targets: Map<number, Cell>; // 方块 id -> 目标格子
  absorbed: Set<number>; // 被合并吸收、动画结束后需移除的方块 id
  newValues: Map<number, number>; // 合并幸存者 id -> 翻倍后的数值

  constructor(moved: boolean, targets: Map<number, Cell>,
    absorbed: Set<number>, newValues: Map<number, number>) {
    this.moved = moved;
    this.targets = targets;
    this.absorbed = absorbed;
    this.newValues = newValues;
  }
}

// 返回某方向上「从移动边缘向内」的遍历坐标，每条线 N 个格子。
function lineCoords(dir: number): Cell[][] {
  const lines: Cell[][] = [];
  for (let a = 0; a < N; a++) {
    const line: Cell[] = [];
    for (let b = 0; b < N; b++) {
      let r: number = 0;
      let c: number = 0;
      if (dir === 3) { // 左：每行，列 0..3
        r = a;
        c = b;
      } else if (dir === 1) { // 右：每行，列 3..0
        r = a;
        c = N - 1 - b;
      } else if (dir === 0) { // 上：每列，行 0..3
        r = b;
        c = a;
      } else { // 下：每列，行 3..0
        r = N - 1 - b;
        c = a;
      }
      line.push(new Cell(r, c));
    }
    lines.push(line);
  }
  return lines;
}

// 推导一次移动：合并规则与 Go 的 slideRow 完全一致（沿移动方向的前一个方块为幸存者）。
export function computeMove(tiles: Tile[], dir: number): MovePlan {
  const grid: Array<Array<Tile | null>> = [];
  for (let i = 0; i < N; i++) {
    const row: Array<Tile | null> = [];
    for (let j = 0; j < N; j++) {
      row.push(null);
    }
    grid.push(row);
  }
  for (const t of tiles) {
    grid[t.row][t.col] = t;
  }

  const targets: Map<number, Cell> = new Map();
  const absorbed: Set<number> = new Set();
  const newValues: Map<number, number> = new Map();
  let moved: boolean = false;

  const lines: Cell[][] = lineCoords(dir);
  for (const line of lines) {
    // 沿处理顺序收集该线上的非空方块
    const seq: Tile[] = [];
    for (const cell of line) {
      const t: Tile | null = grid[cell.row][cell.col];
      if (t !== null) {
        seq.push(t);
      }
    }

    let slot: number = 0; // 下一个落点在 line 中的序号
    let i: number = 0;
    while (i < seq.length) {
      const cur: Tile = seq[i];
      const dest: Cell = line[slot];
      const next: Tile | null = (i + 1 < seq.length) ? seq[i + 1] : null;
      if (next !== null && next.value === cur.value) {
        // 合并：cur 幸存并翻倍，next 被吸收
        targets.set(cur.id, dest);
        targets.set(next.id, dest);
        newValues.set(cur.id, cur.value * 2);
        absorbed.add(next.id);
        moved = true;
        slot++;
        i += 2;
      } else {
        targets.set(cur.id, dest);
        if (dest.row !== cur.row || dest.col !== cur.col) {
          moved = true;
        }
        slot++;
        i++;
      }
    }
  }
  return new MovePlan(moved, targets, absorbed, newValues);
}
