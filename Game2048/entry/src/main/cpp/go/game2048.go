// Package main 实现 2048 的全部游戏逻辑，并通过 CGO 以 c-shared 方式
// 导出 C ABI 函数，供 HarmonyOS 的 NAPI 原生模块调用。
//
// 设计要点：
//   - 游戏状态保存在 Go 侧全局变量中（带互斥锁），C 侧无需管理结构体内存。
//   - 所有对外函数都返回一段 JSON 文本（*C.char），调用方用完后必须调用
//     Game2048Free 释放，避免内存泄漏。
//   - 方向编码：0=上 1=右 2=下 3=左。
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"math/rand"
	"sync"
	"unsafe"
)

const N = 4 // 棋盘边长

type state struct {
	Board [N][N]int `json:"board"`
	Score int       `json:"score"`
	Over  bool      `json:"over"` // 无法再移动
	Won   bool      `json:"won"`  // 出现过 2048
}

var (
	mu sync.Mutex
	g  state
)

// emptyCells 返回所有空格坐标。
func emptyCells() [][2]int {
	var cells [][2]int
	for i := 0; i < N; i++ {
		for j := 0; j < N; j++ {
			if g.Board[i][j] == 0 {
				cells = append(cells, [2]int{i, j})
			}
		}
	}
	return cells
}

// spawn 在随机空格生成一个新数字：90% 概率为 2，10% 为 4。
func spawn() {
	cells := emptyCells()
	if len(cells) == 0 {
		return
	}
	c := cells[rand.Intn(len(cells))]
	v := 2
	if rand.Intn(10) == 0 {
		v = 4
	}
	g.Board[c[0]][c[1]] = v
}

// slideRow 把一行向左压缩并合并，返回新行、本次得分、是否发生变化。
func slideRow(row [N]int) ([N]int, int, bool) {
	vals := make([]int, 0, N)
	for _, v := range row {
		if v != 0 {
			vals = append(vals, v)
		}
	}
	score := 0
	merged := make([]int, 0, N)
	for i := 0; i < len(vals); i++ {
		if i+1 < len(vals) && vals[i] == vals[i+1] {
			nv := vals[i] * 2
			merged = append(merged, nv)
			score += nv
			i++ // 跳过被合并的下一个
		} else {
			merged = append(merged, vals[i])
		}
	}
	var out [N]int
	copy(out[:], merged)
	return out, score, out != row
}

func transpose() {
	for i := 0; i < N; i++ {
		for j := i + 1; j < N; j++ {
			g.Board[i][j], g.Board[j][i] = g.Board[j][i], g.Board[i][j]
		}
	}
}

func reverseRows() {
	for i := 0; i < N; i++ {
		for l, r := 0, N-1; l < r; l, r = l+1, r-1 {
			g.Board[i][l], g.Board[i][r] = g.Board[i][r], g.Board[i][l]
		}
	}
}

// slideLeft 把整个棋盘向左滑动一格，返回是否有任何变化。
func slideLeft() bool {
	moved := false
	for i := 0; i < N; i++ {
		out, score, m := slideRow(g.Board[i])
		g.Board[i] = out
		g.Score += score
		if m {
			moved = true
		}
	}
	return moved
}

// move 按方向移动棋盘，统一转化为「向左滑动」处理。
func move(dir int) bool {
	var moved bool
	switch dir {
	case 3: // 左
		moved = slideLeft()
	case 1: // 右
		reverseRows()
		moved = slideLeft()
		reverseRows()
	case 0: // 上
		transpose()
		moved = slideLeft()
		transpose()
	case 2: // 下
		transpose()
		reverseRows()
		moved = slideLeft()
		reverseRows()
		transpose()
	}
	return moved
}

// canMove 判断是否还有合法移动（存在空格或相邻相等）。
func canMove() bool {
	for i := 0; i < N; i++ {
		for j := 0; j < N; j++ {
			if g.Board[i][j] == 0 {
				return true
			}
			if j+1 < N && g.Board[i][j] == g.Board[i][j+1] {
				return true
			}
			if i+1 < N && g.Board[i][j] == g.Board[i+1][j] {
				return true
			}
		}
	}
	return false
}

// refreshFlags 更新 over / won 状态。
func refreshFlags() {
	g.Over = !canMove()
	for i := 0; i < N; i++ {
		for j := 0; j < N; j++ {
			if g.Board[i][j] >= 2048 {
				g.Won = true
			}
		}
	}
}

// snapshot 把当前状态序列化为 JSON 并以 C 字符串返回（调用方负责 Free）。
func snapshot() *C.char {
	refreshFlags()
	b, _ := json.Marshal(g)
	return C.CString(string(b))
}

//export Game2048New
func Game2048New() *C.char {
	mu.Lock()
	defer mu.Unlock()
	g = state{}
	spawn()
	spawn()
	return snapshot()
}

//export Game2048Move
func Game2048Move(dir C.int) *C.char {
	mu.Lock()
	defer mu.Unlock()
	if move(int(dir)) {
		spawn()
	}
	return snapshot()
}

//export Game2048State
func Game2048State() *C.char {
	mu.Lock()
	defer mu.Unlock()
	return snapshot()
}

//export Game2048Free
func Game2048Free(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {} // c-shared 模式要求存在 main，但不会被调用
