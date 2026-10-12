// Package httpauth 网关 Bearer 鉴权原语。
//
// 单独成包的原因：server（/v1/*、/status）与 panel（/panel/api/*）两处鉴权
// 必须完全同口径——此前各自复制了一份"字符串直接比较"的实现，既容易漂移，
// 又都带计时侧信道。统一到这里后，口径只有一份，且天然常量时间比较。
package httpauth

import (
	"crypto/sha256"
	"crypto/subtle"
	"net/http"
	"strings"
)

// bearerPrefix 认证方案前缀（大小写敏感，与 HTTP 规范及既有实现一致）。
const bearerPrefix = "Bearer "

// VerifyBearer 校验请求头是否携带正确的 Bearer 密钥。
//
// key 为空表示"未启用鉴权"，恒返回 true（调用方据此放行）。
// 比较用 SHA-256 摘要 + subtle.ConstantTimeCompare：
//   - 常量时间，不因前缀匹配长度而泄露信息；
//   - 先摘要再比较，长度差异被吸收进摘要（不会因长度不同提前返回）；
//   - 摘要本身不可逆，即便有侧信道也拿不到密钥原文。
func VerifyBearer(r *http.Request, key string) bool {
	_, ok := MatchBearer(r, key)
	return ok
}

// MatchBearer 在多个密钥中匹配 Authorization: Bearer token。
//
// 返回命中的密钥，供调用方把用量归属到具体 key；keys 全为空表示“未启用鉴权”，
// 恒返回 ("", true)。比较仍走 SHA-256 + constant-time，保持既有防侧信道语义。
func MatchBearer(r *http.Request, keys ...string) (string, bool) {
	var valid []string
	for _, key := range keys {
		if key != "" {
			valid = append(valid, key)
		}
	}
	if len(valid) == 0 {
		return "", true
	}
	authz := r.Header.Get("Authorization")
	if !strings.HasPrefix(authz, bearerPrefix) {
		// 缺头/方案不对：仍做一次摘要比较，保持耗时形状一致。
		for _, key := range valid {
			subtle.ConstantTimeCompare(digest(""), digest(key))
		}
		return "", false
	}
	tok := authz[len(bearerPrefix):]
	target := digest(tok)
	for _, key := range valid {
		if subtle.ConstantTimeCompare(target, digest(key)) == 1 {
			return key, true
		}
	}
	return "", false
}

// digest 返回 s 的 SHA-256（定长 32 字节，供常量时间比较）。
func digest(s string) []byte {
	sum := sha256.Sum256([]byte(s))
	return sum[:]
}
