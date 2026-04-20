            $response = $httpClient.SendAsync($request).GetAwaiter().GetResult()

            if (-not $response.IsSuccessStatusCode -and [int]$response.StatusCode -notin @(200, 201, 202, 206)) {
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                throw "Upload chunk failed ($([int]$response.StatusCode)): $body"
            }