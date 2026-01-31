// Package config provides utilities to load API environment variables & set config structs, it includes app, token, redis cache, db, payment api and http server environment variables.
package config

import (
	"log"
	"strings"

	"github.com/spf13/viper"
	"go.uber.org/zap/zapcore"
)

// AppConfig contains environment variables for the application, database, cache, token, payment api, and http server
type (
	AppConfig struct {
		App    *App    `mapstructure:"app"`
		Redis  *Redis  `mapstructure:"redis"`
		Logger *Logger `mapstructure:"logger"`
		DB     *DB     `mapstructure:"db"`
	}

	// App contains all the environment variables for the application
	App struct {
		Name  string `mapstructure:"name"`
		Env   string `mapstructure:"env"`
		Owner string `mapstructure:"owner"`
	}

	// Redis contains all the environment variables for the cache service
	Redis struct {
		Host     string `mapstructure:"host"`
		Port     string `mapstructure:"port"`
		Addr     string `mapstructure:"addr"`
		Password string `mapstructure:"password"`
	}

	// DB contains all the environment variables for the database
	DB struct {
		Connection string `mapstructure:"connection"`
		Database   string `mapstructure:"database"`
		Host       string `mapstructure:"host"`
		Port       string `mapstructure:"port"`
		User       string `mapstructure:"user"`
		Password   string `mapstructure:"password"`
		Name       string `mapstructure:"name"`
	}

	// Logger contains all the environment variables for the logger
	Logger struct {
		Level             string                `mapstructure:"level"`
		Development       bool                  `mapstructure:"development"`
		DisableStacktrace bool                  `mapstructure:"disableStacktrace"`
		Encoding          string                `mapstructure:"encoding"`
		EncoderConfig     zapcore.EncoderConfig `mapstructure:"encoderConfig"`
	}
)

// addZapEncoderConfig fills encoder config with zapcore types
func addZapEncoderConfig(cfg *zapcore.EncoderConfig) {
	cfg.EncodeLevel = zapcore.CapitalLevelEncoder
	cfg.EncodeTime = zapcore.ISO8601TimeEncoder
	cfg.EncodeDuration = zapcore.SecondsDurationEncoder
	cfg.EncodeCaller = zapcore.ShortCallerEncoder
	cfg.EncodeName = func(s string, pae zapcore.PrimitiveArrayEncoder) {
		pae.AppendString("[" + s + "]")
	}
}

// New creates a new AppConfig instance
func New() *AppConfig {
	// Set up viper to read the config.yaml file
	viper.SetConfigName("config")
	viper.SetConfigType("yaml")
	viper.AddConfigPath(".")
	viper.AddConfigPath("/etc/secrets/")

	viper.AutomaticEnv()
	viper.SetEnvPrefix("env")
	viper.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))

	// Read the config file
	if err := viper.ReadInConfig(); err != nil {
		if _, ok := err.(viper.ConfigFileNotFoundError); ok {
			log.Fatalf("config file not found: %v", err)
		} else {
			log.Fatalf("error reading config file: %v", err)
		}
	}

	// Bind the app.name key to the APP_NAME environment variable
	if err := viper.BindEnv("app.name", "APP_NAME"); err != nil {
		log.Fatalf("error finding APP_NAME env variable")
	}

	// Bind DB variables
	viper.BindEnv("db.host", "PG_HOST")
	viper.BindEnv("db.port", "PG_PORT")
	viper.BindEnv("db.user", "PG_USER")
	viper.BindEnv("db.password", "PG_PASS")
	viper.BindEnv("db.name", "PG_DB")

	// Bind Redis variables
	viper.BindEnv("redis.addr", "REDIS_ADDR")
	viper.BindEnv("redis.password", "REDIS_PASSWORD")

	// Create an instance of AppConfig
	var config *AppConfig
	if err := viper.Unmarshal(&config); err != nil {
		log.Fatalf("unable to decode into struct: %v", err)
	}
	addZapEncoderConfig(&config.Logger.EncoderConfig)

	return config
}
