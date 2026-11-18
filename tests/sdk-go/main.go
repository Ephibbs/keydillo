// Checks which Go SDKs send requests to a base URL taken from the environment, the way `kd` sets it.
// Run: go run . (with a mock server listening; see run.sh)
package main

import (
	"context"
	"fmt"
	"os"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/openai/openai-go/v3"
	goopenai "github.com/sashabaranov/go-openai"
)

func main() {
	ctx := context.Background()
	switch os.Args[1] {
	case "openai-go":
		c := openai.NewClient()
		_, err := c.Models.List(ctx)
		fmt.Println("openai-go", err)
	case "anthropic-sdk-go":
		c := anthropic.NewClient()
		_, err := c.Models.List(ctx, anthropic.ModelListParams{})
		fmt.Println("anthropic-sdk-go", err)
	case "go-openai":
		c := goopenai.NewClient(os.Getenv("OPENAI_API_KEY"))
		_, err := c.ListModels(ctx)
		fmt.Println("go-openai", err)
	}
}
