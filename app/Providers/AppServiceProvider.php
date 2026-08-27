<?php

namespace App\Providers;

use Illuminate\Support\Facades\URL;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
        //
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        if ($this->app->runningInConsole()) {
            if ($appUrl = config('app.url')) {
                URL::forceRootUrl($appUrl);
            }

            return;
        }

        if (config('app.trust_request_host')) {
            URL::forceRootUrl(request()->getSchemeAndHttpHost());

            return;
        }

        if ($appUrl = config('app.url')) {
            URL::forceRootUrl($appUrl);
        }
    }
}
