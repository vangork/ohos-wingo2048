// libentry.so 的 ArkTS 类型声明。
// 所有方法返回游戏状态的 JSON 字符串：
//   { "board": number[4][4], "score": number, "over": boolean, "won": boolean }
export const newGame: () => string;
export const state: () => string;
// dir: 0=上 1=右 2=下 3=左
export const move: (dir: number) => string;
