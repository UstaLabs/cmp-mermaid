package com.swithun.cmpmermaid.legacyaudit

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.swithun.cmpmermaid.compose.MermaidDiagram
import com.swithun.cmpmermaid.core.GMResult
import com.swithun.cmpmermaid.core.MermaidRenderOptions
import com.swithun.cmpmermaid.debugui.generated.StabilityCorpusCase
import com.swithun.cmpmermaid.debugui.generated.productionCorpusCases
import kotlinx.coroutines.delay

class LegacyMermaidAuditActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val auditCaseId = intent.getStringExtra(EXTRA_AUDIT_DEMO_ID)
        val layoutOverride = intent.getStringExtra(EXTRA_AUDIT_LAYOUT)
        setContent {
            when {
                auditCaseId != null -> StandaloneAuditScreen(
                    caseId = auditCaseId,
                    layoutOverride = layoutOverride,
                )
                intent.getBooleanExtra(EXTRA_OPEN_LOAD_TEST, false) ->
                    ProductionLoadAuditScreen()
                else -> AuditLauncherScreen()
            }
        }
    }

    companion object {
        private const val EXTRA_AUDIT_DEMO_ID = "auditDemoId"
        private const val EXTRA_AUDIT_LAYOUT = "auditLayout"
        private const val EXTRA_OPEN_LOAD_TEST = "openLoadTest"
    }
}

@Composable
private fun AuditLauncherScreen() {
    AuditSurface {
        BasicText(
            text = "CMP Mermaid Kotlin 1.7 device audit",
            style = titleStyle,
        )
    }
}

@Composable
private fun ProductionLoadAuditScreen() {
    var caseIndex by remember { mutableStateOf(0) }
    var renderedCaseId by remember { mutableStateOf<String?>(null) }
    var failedCaseId by remember { mutableStateOf<String?>(null) }
    var completed by remember { mutableStateOf(false) }
    val case = productionCorpusCases[caseIndex]

    LaunchedEffect(caseIndex) {
        renderedCaseId = null
        failedCaseId = null
    }
    LaunchedEffect(renderedCaseId) {
        if (renderedCaseId != case.id || completed) {
            return@LaunchedEffect
        }
        delay(AUTO_ADVANCE_DELAY_MILLIS)
        if (caseIndex == productionCorpusCases.lastIndex) {
            completed = true
            println("$LOAD_TEST_COMPLETE_MARKER ${case.id}")
        } else {
            caseIndex += 1
        }
    }

    AuditSurface {
        BasicText(
            text = "Kotlin 1.7.21 Android audit",
            style = titleStyle,
        )
        BasicText(
            text = if (completed) {
                "${productionCorpusCases.size}/${productionCorpusCases.size} rendered"
            } else {
                "${caseIndex + 1}/${productionCorpusCases.size} ${case.id}"
            },
            style = statusStyle,
        )
        MermaidDiagram(
            source = case.source,
            options = MermaidRenderOptions(layout = case.layout),
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .background(Color.White),
            respectSourceViewportSizing = false,
            onRenderResult = { result ->
                when (result) {
                    is GMResult.Ok -> renderedCaseId = case.id
                    is GMResult.Err -> {
                        if (failedCaseId != case.id) {
                            failedCaseId = case.id
                            println(
                                "$LOAD_TEST_FAILURE_MARKER ${case.id}: " +
                                    result.error,
                            )
                        }
                    }
                }
            },
        )
    }
}

@Composable
private fun StandaloneAuditScreen(
    caseId: String,
    layoutOverride: String?,
) {
    val case = remember(caseId) {
        productionCorpusCases.firstOrNull { it.id == caseId }
    }
    AuditSurface {
        if (case == null) {
            BasicText(
                text = "Unknown audit case: $caseId",
                style = titleStyle,
            )
            return@AuditSurface
        }
        BasicText(text = case.title, style = titleStyle)
        BasicText(text = case.id, style = statusStyle)
        StandaloneDiagram(
            case = case,
            layout = layoutOverride ?: case.layout,
        )
    }
}

@Composable
private fun ColumnScope.StandaloneDiagram(
    case: StabilityCorpusCase,
    layout: String,
) {
    var auditStatus by remember(case.id) {
        mutableStateOf(AUDIT_STATUS_LOADING)
    }
    MermaidDiagram(
        source = case.source,
        options = MermaidRenderOptions(layout = layout),
        modifier = Modifier
            .fillMaxWidth()
            .weight(1f)
            .background(Color.White)
            .semantics {
                contentDescription = auditStatus
            },
        respectSourceViewportSizing = false,
        onRenderResult = { result ->
            when (result) {
                is GMResult.Ok -> {
                    auditStatus = "$AUDIT_STATUS_READY_PREFIX${case.id}"
                }
                is GMResult.Err -> {
                    auditStatus = "$AUDIT_STATUS_ERROR_PREFIX${case.id}"
                    println("$VISUAL_FAILURE_MARKER ${case.id}: ${result.error}")
                }
            }
        },
    )
}

@Composable
private fun AuditSurface(content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFFF7F8FA))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        content = content,
    )
}

private val titleStyle = TextStyle(
    color = Color(0xFF17191C),
    fontSize = 18.sp,
    fontWeight = FontWeight.SemiBold,
)

private val statusStyle = TextStyle(
    color = Color(0xFF4E5969),
    fontSize = 12.sp,
)

private const val AUTO_ADVANCE_DELAY_MILLIS = 75L
private const val LOAD_TEST_COMPLETE_MARKER = "CMP_MERMAID_LOAD_TEST_COMPLETE"
private const val LOAD_TEST_FAILURE_MARKER = "CMP_MERMAID_LOAD_TEST_FAILED"
private const val VISUAL_FAILURE_MARKER = "CMP_MERMAID_VISUAL_TEST_FAILED"
private const val AUDIT_STATUS_LOADING = "cmp-mermaid-audit:loading"
private const val AUDIT_STATUS_READY_PREFIX = "cmp-mermaid-audit:ready:"
private const val AUDIT_STATUS_ERROR_PREFIX = "cmp-mermaid-audit:error:"
