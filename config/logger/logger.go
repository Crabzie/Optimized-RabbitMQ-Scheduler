// Package logger provides zap logger implimentation logic.
package logger

import (
	"log"
	"os"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"

	config "github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/utils"
	"github.com/fsnotify/fsnotify"
	"github.com/spf13/viper"
)

// atomicLevel is logger log level invariant
var atomicLevel zap.AtomicLevel

// Build is a build function that's responsible for setting up base logger
func Build(config *config.Logger) *zap.Logger {
	// Parse AtomicLevel from string
	t, err := zap.ParseAtomicLevel(config.Level)
	if err != nil {
		log.Fatalf("Couldn't parse initial atomic level at logger build: %v", err)
	}
	atomicLevel = t

	// create encoder
	encoder := zapcore.NewJSONEncoder(config.EncoderConfig)
	if config.Encoding == "console" {
		encoder = zapcore.NewConsoleEncoder(config.EncoderConfig)
	}

	// Level filters
	highPriority := zap.LevelEnablerFunc(func(lvl zapcore.Level) bool {
		return lvl >= zapcore.ErrorLevel
	})

	lowPriority := zap.LevelEnablerFunc(func(lvl zapcore.Level) bool {
		return atomicLevel.Enabled(lvl) && lvl < zapcore.ErrorLevel
	})

	infoCore := zapcore.NewCore(encoder, os.Stdout, lowPriority)
	errorCore := zapcore.NewCore(encoder, os.Stderr, highPriority)

	// Build logger
	logger := zap.New(zapcore.NewTee(infoCore, errorCore), zap.AddCaller())
	zap.ReplaceGlobals(logger)

	viper.OnConfigChange(func(in fsnotify.Event) {
		if in.Op&(fsnotify.Create) == 0 {
			SetLevel(viper.GetString("logger.level"))
		}
	})
	viper.WatchConfig()
	return logger
}

// SetLevel changes logger level dynamically
func SetLevel(level string) {
	l, err := zapcore.ParseLevel(level)
	if err != nil {
		zap.L().Error("Couldn't parse level", zap.Error(err))
	} else {
		zap.L().Info("Atomic level updated", zap.String("value", level))
		atomicLevel.SetLevel(l)
	}
}
