import Foundation
func check(_ input: String, _ expected: String, _ role: String = "user") {
    precondition(WorkBuddyTasksReader.displayText(input, role: role) == expected)
}
check("<system-reminder>internal</system-reminder>\n<user_query>整理日报</user_query>\n<additional_data><current_time>now</current_time></additional_data>\n<memory_and_skills_reminder>Skills: internal</memory_and_skills_reminder>", "整理日报")
check("你好\n<memory_and_skills_reminder>internal</memory_and_skills_reminder>", "你好")
check("<system-reminder>only internal</system-reminder>", "")
check("正常回复 <b>加粗</b>", "正常回复 <b>加粗</b>", "assistant")
check("讨论 memory 和 skills 的使用方法", "讨论 memory 和 skills 的使用方法")
check("<user_query>第一段\n第二段</user_query>", "第一段\n第二段")
check("<user_query>比较 <system-reminder>示例</system-reminder> 标签</user_query>", "比较 <system-reminder>示例</system-reminder> 标签")
check("回答\n<memory_and_skills_reminder>unfinished", "回答", "assistant")
print("PASS: wrapped requests, internal-only messages, normal text and incomplete reminders")
