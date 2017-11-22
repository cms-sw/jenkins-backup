import jenkins.model.*
import java.util.logging.Logger

for (plugin in Jenkins.instance.pluginManager.plugins)
{
  if (plugin.isEnabled())
    println ("${plugin.getShortName()}:${plugin.getVersion()}")
}

