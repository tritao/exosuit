package com.exosuit.mobile

import android.content.Context
import android.content.pm.ApplicationInfo
import android.system.Os
import android.util.AtomicFile
import android.util.Base64
import java.io.File
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * NativeKit's TLS (Mbed TLS under libwebsockets) has no system trust store on Android. This exports the system's public
 * CA roots to a PEM file and points NK_ANDROID_TLS_CA_FILE at it; it must run before the first secure connection.
 * The file holds public certificates only.
 *
 * Debug builds only (FLAG_DEBUGGABLE): a development CA in `files/dev-ca.pem` (written by scripts/e2e-local.ps1 with
 * `adb run-as`) is trusted in addition, both by the native TLS (appended to the PEM) and by the platform's HTTPS
 * (`HttpsURLConnection` default), so a local relay with a locally generated certificate works. Without the file, or in
 * a release build, nothing changes.
 */
object TlsTrust {
    private const val VARIABLE = "NK_ANDROID_TLS_CA_FILE"

    fun install(context: Context) {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(null as KeyStore?)
        val issuers = factory.trustManagers.filterIsInstance<X509TrustManager>().flatMap { it.acceptedIssuers.toList() }
        val development = developmentAuthorities(context)
        val certificates = (issuers + development).map { Base64.encodeToString(it.encoded, Base64.NO_WRAP) }.distinct().sorted()
        check(certificates.isNotEmpty()) { "Android TLS trust anchors unavailable" }
        val directory = File(context.filesDir, "native-tls")
        check(directory.isDirectory || directory.mkdirs()) { "Could not create the TLS trust directory" }
        val target = AtomicFile(File(directory, "android-roots.pem"))
        val output = target.startWrite()
        try {
            for (certificate in certificates) {
                output.write("-----BEGIN CERTIFICATE-----\n".toByteArray(Charsets.US_ASCII))
                for (line in certificate.chunked(64)) output.write((line + "\n").toByteArray(Charsets.US_ASCII))
                output.write("-----END CERTIFICATE-----\n".toByteArray(Charsets.US_ASCII))
            }
            target.finishWrite(output)
        } catch (error: Throwable) {
            target.failWrite(output)
            throw error
        }
        Os.setenv(VARIABLE, target.baseFile.absolutePath, true)
        if (development.isNotEmpty()) trustPlatformHttps(development)
    }

    private fun developmentAuthorities(context: Context): List<X509Certificate> {
        if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return emptyList()
        val file = File(context.filesDir, "dev-ca.pem")
        if (!file.isFile) return emptyList()
        return file.inputStream().use { CertificateFactory.getInstance("X.509").generateCertificates(it) }.filterIsInstance<X509Certificate>()
    }

    /** The platform's HTTPS (NativeKit's HTTP client on Android) trusts the system roots plus the development CA. */
    private fun trustPlatformHttps(extra: List<X509Certificate>) {
        val store = KeyStore.getInstance(KeyStore.getDefaultType())
        store.load(null, null)
        val system = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        system.init(null as KeyStore?)
        system.trustManagers.filterIsInstance<X509TrustManager>().flatMap { it.acceptedIssuers.toList() }
            .forEachIndexed { index, certificate -> store.setCertificateEntry("system-$index", certificate) }
        extra.forEachIndexed { index, certificate -> store.setCertificateEntry("development-$index", certificate) }
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(store)
        val context = SSLContext.getInstance("TLS")
        context.init(null, factory.trustManagers, null)
        HttpsURLConnection.setDefaultSSLSocketFactory(context.socketFactory)
    }
}
